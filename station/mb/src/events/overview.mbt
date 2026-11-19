// GET /overview (station/src/api/overview.ts): the station as its settings pages show it, as the viewer sees it: the
// connects of their workspace, the agents' processes and what they hold, counts, the disk, logins, updates, the
// settings, the automatic decisions. What other parts of the station make (the accounts' views, the archive policy's,
// the store's counts, the machine's measures) is asked of `OverviewDeps`, each answer given when it comes.

///|
/// accounts/index.ts as the overview asks it.
pub(all) struct AccountsDeps {
  /// What each profile's home says read first (`homesReadSoon`).
  homes_read_soon : ((() -> Unit) -> Unit)?
  profiles_view : (Viewer) -> J
  logins_view : (Viewer) -> J
  api_providers : () -> J
  machine_logins : () -> J
  decision_models : () -> J
  /// `automaticDecisionsView(viewer, {includePolicy: false, visible, title})`; none: the sessions it names are not
  /// ready to be looked up yet (DecisionSessionsUnavailable).
  automatic_decisions_view : (Viewer, (J) -> Bool, (String) -> String) -> J?
}

///|
/// How a kind's connects show (connects/part.ts `ConnectKind`).
pub(all) struct ConnectKind {
  shown : (J) -> J
  connection : (J) -> J?
}

///|
pub(all) struct OverviewDeps {
  config : () -> J
  /// store.overviewSessionCounts: (total, by connect), none until they are counted.
  session_counts : (Viewer, Array[J]) -> (Double, Map[String, Double])?
  wait_for_session_counts : (((Bool) -> Unit) -> Unit)?
  hub_processes : () -> Array[(String, String)]
  session_ws : (String) -> J?
  list_processes : () -> Array[J]
  data_dir : String
  /// platform.groupMemory: kB by process group (by the group's number as JSON).
  group_memory : (Array[J], (Map[String, Double]) -> Unit) -> Unit
  /// The data disk's room (`diskRoom`), never failing.
  disk_room : (String, (J) -> Unit) -> Unit
  store_now : () -> Double
  binding : (String) -> J
  connect_kind : (String) -> ConnectKind?
  accounts : AccountsDeps?
  updates : ((String) -> J)?
  slack_identities : (String) -> J
  root_view : (String, (J) -> Unit) -> Unit
  homedir : String
  has_spotlight : Bool
  permissions : ((Viewer) -> J?)?
  /// still.fail cloud's state (cloud.json; none: off), a workspace's membership, whether it is heard now.
  cloud_state : () -> J?
  membership : (String) -> J?
  reached : () -> Bool
  /// accounts/catalog.ts `catalog().models`: what the catalog says of each model, by its key.
  catalog : () -> J
  /// The automatic decisions' parts: the store's version of them, the archive policy's view (archive-policy.ts
  /// `policyView`, given the checks counted by a reader or none), and the reads that prepare the chats' names.
  decisions_version : () -> J
  policy_checks : ((Double, Viewer, (J) -> Unit) -> Unit)?
  policy_view : (J, (J) -> Bool, (String) -> String, Viewer, J?) -> J
  prepare_decision_sessions : (() -> Unit) -> Unit
  prepare_session_chat_names : ((Array[String], () -> Unit) -> Unit)?
  session_there : (String) -> Bool
  chat_readable : (String) -> Bool
  /// overview.ts `chatTitleOf`: what a session's chat is called in the chat list.
  chat_title : (String) -> String
  /// The platform's paths: whether one is absolute, and it cleaned (platform.paths `rooted`, `clean`).
  rooted : (String) -> Bool
  clean : (String) -> String
  /// Unix ms timestamp when this station release was built (ops/version.ts `builtAt`); None in development.
  built_at : Double?
}

///|
/// What an overview keeps between viewers' (overview.ts `memoryKept`, `decisionsKept`): a store's.
pub struct OverviewKept {
  mut memory : (Double, String, Map[String, Double])?
  decisions : Map[String, (Double, String, J)]
}

///|
pub fn OverviewKept::new() -> OverviewKept {
  { memory: None, decisions: Map([]), }
}

///|
let memory_kept_ms : Double = 5_000.0

///|
let decisions_kept_ms : Double = 60_000.0

///|
/// archive-policy.ts VIEW_DAYS, and `policySince`.
let view_days : Double = 7.0

///|
/// `a ?? b`.
fn either(a : J?, b : J?) -> J? {
  match a {
    None | Some(Null) => b
    _ => a
  }
}

///|
/// JavaScript's truthiness.
fn truthy(v : J?) -> Bool {
  match v {
    None | Some(Null) => false
    Some(Bool(b)) => b
    Some(Num(n)) => !(n == 0.0 || n.is_nan())
    Some(Str(s)) => s.length() > 0
    _ => true
  }
}

///|
/// Math.round.
fn js_round(x : Double) -> Double {
  (x + 0.5).floor()
}

///|
/// What a plain object has of its own besides (`m in {}`): Object.prototype's names.
let prototype_names : Array[String] = [
  "constructor", "hasOwnProperty", "isPrototypeOf", "propertyIsEnumerable", "toLocaleString",
  "toString", "valueOf", "__proto__", "__defineGetter__", "__defineSetter__", "__lookupGetter__",
  "__lookupSetter__",
]

///|
/// overview.ts `meshStatus`: this station's link to still.fail cloud in the viewer's workspace.
pub fn mesh_status(d : OverviewDeps, viewer : Viewer?) -> J {
  guard (d.cloud_state)() is Some(s) && !(s is Null) else {
    return jo([
      ("state", js("off")),
      ("origin", Null),
      ("station", Null),
      ("workspace", Null),
      ("workspaceId", Null),
      ("name", Null),
    ])
  }
  let m = match viewer {
    None => None
    Some(v) => (d.membership)(v.workspace)
  }
  let m = match m {
    Some(Null) => None
    other => other
  }
  let mf = (name : String) => {
    match m {
      Some(m) => m.get(name)
      None => None
    }
  }
  let removed = s.get("removed_at")
  jopt([
    ("state", Some(js(if removed is Some(_) { "removed" } else { "running" }))),
    ("origin", Some(either(s.get("origin"), None).unwrap_or(Null))),
    ("station", Some(either(s.get("station"), None).unwrap_or(Null))),
    (
      "workspace",
      Some(
        either(mf("workspace_name"), s.get("workspace_name")).unwrap_or(Null),
      ),
    ),
    (
      "workspaceId",
      Some(either(mf("workspace"), s.get("workspace")).unwrap_or(Null)),
    ),
    ("name", Some(either(mf("name"), s.get("name")).unwrap_or(Null))),
    ("reached", Some(Bool((d.reached)()))),
    ("removedAt", removed),
  ])
}

///|
/// overview.ts `archivingView`.
fn archiving_view(raw : J, viewer : Viewer) -> J {
  let days = (v : J?, fallback : Double) => {
    match v {
      Some(Num(n)) if !n.is_nan() && !n.is_inf() =>
        if n > 0.0 {
          n
        } else {
          0.0
        }
      _ => fallback
    }
  }
  jo([
    ("days", jn(days(raw.get("autoArchiveDays"), 1.0))),
    ("slackDays", jn(days(raw.get("slackArchiveDays"), 3.0))),
    ("reviewed", Bool(raw.get("autoArchiveReviewed") is Some(Bool(true)))),
    ("canEdit", Bool(manages_station(viewer.role))),
  ])
}

///|
/// ops/agent-env.ts ENV_NAME.
fn env_name(key : String) -> Bool {
  key.length() > 0 &&
  key
  .iter()
  .all(c => {
    (c >= 'A' && c <= 'Z') ||
    (c >= 'a' && c <= 'z') ||
    c == '_' ||
    (c >= '0' && c <= '9')
  }) &&
  !(key.unsafe_charcode_at(0) >= '0'.to_int() &&
  key.unsafe_charcode_at(0) <= '9'.to_int())
}

///|
/// agent-env.ts `secretValue`: a key, a token, a proxy's password.
fn secret_value(key : String, value : String) -> Bool {
  let upper = key.to_upper()
  for w in ["KEY", "TOKEN", "SECRET", "PASSWORD", "AUTH"] {
    if upper.contains(w) {
      return true
    }
  }
  // /^[a-z][a-z0-9+.-]*:\/\/[^/@]*:[^/@]*@/i
  let n = value.length()
  let c = (i : Int32) => value.unsafe_charcode_at(i)
  let letter = (x : Int32) => {
    (x >= 'a'.to_int() && x <= 'z'.to_int()) ||
    (x >= 'A'.to_int() && x <= 'Z'.to_int())
  }
  if n == 0 || !letter(c(0)) {
    return false
  }
  let mut i = 1
  while i < n &&
        (
          letter(c(i)) ||
          (c(i) >= '0'.to_int() && c(i) <= '9'.to_int()) ||
          c(i) == '+'.to_int() ||
          c(i) == '.'.to_int() ||
          c(i) == '-'.to_int()
        ) {
    i += 1
  }
  if !(i + 2 < n + 0 &&
    c(i) == ':'.to_int() &&
    c(i + 1) == '/'.to_int() &&
    c(i + 2) == '/'.to_int()) {
    return false
  }
  i += 3
  // [^/@]* : [^/@]* @, the first part as long as it can be and given back as the regex would
  let start = i
  let mut end = start
  while end < n && c(end) != '/'.to_int() && c(end) != '@'.to_int() {
    end += 1
  }
  for colon in start..<end {
    if c(colon) == ':'.to_int() {
      let mut k = colon + 1
      while k < n && c(k) != '/'.to_int() && c(k) != '@'.to_int() {
        k += 1
      }
      if k < n && c(k) == '@'.to_int() {
        return true
      }
    }
  }
  false
}

///|
/// agent-env.ts `maskValue`: its first five and last four characters.
fn mask_value(value : String) -> String {
  if value == "" {
    return ""
  }
  let chars = value.iter().to_array()
  if chars.length() <= 8 {
    return "••••"
  }
  let out = StringBuilder::new()
  for ch in chars[0:5] {
    out.write_char(ch)
  }
  out.write_char('…')
  for ch in chars[chars.length() - 4:] {
    out.write_char(ch)
  }
  out.to_string()
}

///|
/// routes/agent-env.ts `agentEnvView`.
fn agent_env_view(raw : J) -> J {
  let set = match raw.get("agentEnv") {
    Some(Obj(entries)) => entries
    _ => []
  }
  let env = set
    .map(e => (e.0, e.1))
    .filter(e => env_name(e.0) && e.1 is Str(_))
    .map(e => (e.0, text_of(Some(e.1)).unwrap()))
  env.sort_by((a, b) => js_compare(a.0, b.0))
  ja(
    env.map(e => {
      if secret_value(e.0, e.1) {
        jo([
          ("key", js(e.0)),
          ("value", js(mask_value(e.1))),
          ("secret", Bool(true)),
        ])
      } else {
        jo([("key", js(e.0)), ("value", js(e.1)), ("secret", Bool(false))])
      }
    }),
  )
}

///|
/// The setting views (routes/context.ts, routes/diagnostics.ts, mesh/settings.ts).
fn context_view(raw : J) -> J {
  let above = match raw.get("afreshAbove") {
    Some(Num(n)) if !n.is_nan() && !n.is_inf() && n >= 0.0 => n
    _ => 1.0
  }
  jo([
    ("afreshWhenCold", Bool(raw.get("afreshWhenCold") is Some(Bool(true)))),
    ("afreshAbove", jn(above)),
  ])
}

///|
fn diagnostics_view(raw : J) -> J {
  let off = match raw.get("telemetry") {
    Some(t) => t.get("logs") is Some(Bool(false))
    None => false
  }
  jo([("logs", Bool(!off))])
}

///|
fn network_view(raw : J) -> J {
  let bbr = match raw.get("network") {
    Some(n) => text_of(n.get("congestion")) == Some("bbr")
    None => false
  }
  jo([("congestion", js(if bbr { "bbr" } else { "cubic" }))])
}

///|
/// drive.ts `rootsOf`: the roots config.json names, of a joined workspace's or the home one's.
fn roots_of(d : OverviewDeps, raw : J, workspace : String?) -> Array[String] {
  let drive = raw.get("drive")
  let roots = match (drive, workspace) {
    (Some(dr), None) => dr.get("roots")
    (Some(dr), Some(w)) =>
      match dr.get("workspaces") {
        Some(ws) => ws.get(w)
        None => None
      }
    _ => None
  }
  match roots {
    Some(Arr(items)) =>
      items.filter_map(r => {
        match text_of(Some(r)) {
          Some(p) if (d.rooted)(p) => Some((d.clean)(p))
          _ => None
        }
      })
    _ => []
  }
}

///|
/// catalog.ts `facts`, of the catalog's snapshot.
fn facts_of(catalog : J, model : String) -> J? {
  let key = @readops.model_key(model)
  let bare = match key.find("[") {
    Some(at) => key.view(end_offset=at).to_string()
    None => key
  }
  match catalog.get(bare) {
    Some(f) => Some(f)
    None =>
      match @readops.split_agy_tier(bare) {
        Some(m) => catalog.get(m)
        None => None
      }
  }
}

///|
fn profile_models(profiles : J) -> Array[J] {
  let out = []
  if profiles is Arr(items) {
    for p in items {
      if p.get("models") is Some(Arr(models)) {
        out.append(models)
      }
    }
  }
  out
}

///|
/// overview.ts `modelMakers`.
pub fn model_makers(catalog : J, profiles : J) -> J {
  let out : Array[(String, J)] = []
  let named : Map[String, Unit] = Map([])
  for m in profile_models(profiles) {
    guard m is Str(_) else { continue }
    let m = text_of(Some(m)).unwrap()
    if named.contains(m) || prototype_names.contains(m) {
      continue
    }
    guard facts_of(catalog, m) is Some(f) && f.get("maker") is Some(maker) else {
      continue
    }
    named[m] = ()
    out.push(
      (
        m,
        jopt([
          ("maker", Some(maker)),
          ("makerName", f.get("makerName")),
          ("family", f.get("family")),
        ]),
      ),
    )
  }
  jo(out)
}

///|
/// overview.ts `modelWindows`.
pub fn model_windows(catalog : J, profiles : J) -> J {
  let out : Array[(String, J)] = []
  let named : Map[String, Unit] = Map([])
  for m in profile_models(profiles) {
    guard m is Str(_) else { continue }
    let m = text_of(Some(m)).unwrap()
    if named.contains(m) || prototype_names.contains(m) {
      continue
    }
    guard facts_of(catalog, m) is Some(f) &&
      f.get("context") is Some(Num(w)) &&
      w > 0.0 else {
      continue
    }
    named[m] = ()
    out.push((m, jn(w)))
  }
  jo(out)
}

///|
/// overview.ts `keptMemory`: the groups' memory as measured within MEMORY_KEPT_MS for the same groups.
fn kept_memory(
  d : OverviewDeps,
  kept : OverviewKept,
  pgids : Array[J],
  done : (Map[String, Double]) -> Unit,
) -> Unit {
  let key = pgids.map(p => string_of(Some(p))).join(",")
  let now = (d.store_now)()
  if kept.memory is Some((at, k, memory)) &&
    k == key &&
    now - at < memory_kept_ms {
    return done(memory)
  }
  let measured = (memory : Map[String, Double]) => {
    kept.memory = Some((now, key, memory))
    done(memory)
  }
  if pgids.length() == 0 {
    measured(Map([]))
  } else {
    (d.group_memory)(pgids, measured)
  }
}

///|
/// A connect as the pages show it (overview.ts's `connects`).
fn connect_shown(d : OverviewDeps, c : J, sessions_of : (J?) -> Double) -> J {
  let mode = either(c.get("mode"), None).unwrap_or(js("multi-session"))
  let bind = c.get("bind")
  let bind_of = (name : String) => {
    match bind {
      Some(b) => b.get(name)
      None => None
    }
  }
  let non_empty = (v : J?) => {
    match v {
      Some(Str(s)) if s.length() > 0 => Some((Str(s) : J))
      _ => None
    }
  }
  let kind = match c.get("kind") {
    Some(Str(s)) if s.length() > 0 => s
    _ => "slack"
  }
  let profiles : Array[String] = []
  if bind_of("profiles") is Some(Arr(items)) {
    for x in items {
      if text_of(Some(x)) is Some(s) &&
        @jscase.trim(s) != "" &&
        !profiles.contains(@jscase.trim(s)) {
        profiles.push(@jscase.trim(s))
      }
    }
  }
  let single = match non_empty(bind_of("profile")) {
    Some(p) => p
    None => if profiles.length() == 1 { js(profiles[0]) } else { Null }
  }
  let single_session = text_of(Some(mode)) == Some("single-session")
  let multi = text_of(Some(mode)) == Some("multi-session")
  let connection = if c.get("enabled") is Some(Bool(false)) {
    jo([("state", js("disabled"))])
  } else {
    jo([("state", js("starting"))])
  }
  let created_by = match c.get("createdBy") {
    Some(by) if truthy(by.get("id")) => by
    _ => Null
  }
  // (its properties as the object has them, one undefined holding its place: what a kind's own sets goes there)
  let shown : Array[(String, J?)] = [
    ("id", c.get("id")),
    ("name", c.get("id")),
    ("team", Some(Null)),
    ("botImage", Some(Null)),
    ("enabled", Some(either(c.get("enabled"), None).unwrap_or(Bool(true)))),
    ("kind", Some(js(kind))),
    ("mode", Some(mode)),
    (
      "requireMention",
      Some(
        if multi {
          Bool(true)
        } else {
          either(c.get("requireMention"), None).unwrap_or(Bool(true))
        },
      ),
    ),
    (
      "bind",
      Some(
        jopt([
          ("runtime", bind_of("runtime")),
          ("model", Some(non_empty(bind_of("model")).unwrap_or(Null))),
          ("effort", Some(non_empty(bind_of("effort")).unwrap_or(Null))),
          ("profile", Some(single)),
          (
            "profiles",
            if profiles.length() > 1 {
              Some(ja(profiles.map(js)))
            } else {
              None
            },
          ),
        ]),
      ),
    ),
    ("slack", Some(jo([("appToken", js("")), ("botToken", js(""))]))),
    ("connection", Some(connection)),
    ("createdBy", Some(created_by)),
    ("sessions", Some(jn(sessions_of(c.get("id"))))),
    (
      "session",
      Some(
        if single_session {
          (d.binding)(string_of(c.get("id")))
        } else {
          Null
        },
      ),
    ),
    ("startsOn", Some(non_empty(c.get("station")).unwrap_or(Null))),
    ("moves", Some(Bool(true))),
  ]
  let put = (name : String, value : J?) => {
    for i, p in shown {
      if p.0 == name {
        shown[i] = (name, value)
        return
      }
    }
    shown.push((name, value))
  }
  if (d.connect_kind)(kind) is Some(own) {
    if (own.shown)(c) is Obj(entries) {
      for e in entries {
        put(e.0, Some(e.1))
      }
    }
    put(
      "connection",
      Some(either((own.connection)(c), None).unwrap_or(connection)),
    )
  }
  jopt(shown)
}

///|
/// overview.ts `overview`: as `viewer` sees it, in `lang`; an error where the sessions are not counted yet.
pub fn overview(
  d : OverviewDeps,
  kept : OverviewKept,
  viewer : Viewer,
  lang : String,
  done : (Result[J, String]) -> Unit,
) -> Unit {
  let raw = match (d.config)() {
    Null => jo([])
    r => r
  }
  let connects = match raw.get("connects") {
    Some(Arr(items)) =>
      items.filter(c => {
        let ws = match c.get("workspace") {
          Some(Str(s)) if s.length() > 0 => Some(s)
          _ => None
        }
        sees_ws(viewer, ws)
      })
    _ => []
  }
  let ids = connects.map(c => c.get("id").unwrap_or(Null))
  let counted = (counts : (Double, Map[String, Double])) => {
    let (total, by) = counts
    let sessions_of = (connect : J?) => {
      match connect {
        Some(Null) => total
        Some(Str(_) as s) => by.get(text_of(Some(s)).unwrap()).unwrap_or(0.0)
        _ => 0.0
      }
    }
    let states = (d.hub_processes)()
      .filter(p => sees(viewer, (d.session_ws)(p.0).unwrap_or(Null)))
      .map(p => p.1)
    let processes = (d.list_processes)().filter(p => {
      text_of(p.get("runtime")) != Some("job")
    })
    // (the disk's room asked meanwhile: it never fails)
    let disk : Ref[J?] = { val: None, }
    let disk_waiter : Ref[((J) -> Unit)?] = { val: None, }
    (d.disk_room)(d.data_dir, room => {
      disk.val = Some(room)
      if disk_waiter.val is Some(w) {
        w(room)
      }
    })
    let disk_then = (f : (J) -> Unit) => {
      match disk.val {
        Some(room) => f(room)
        None => disk_waiter.val = Some(f)
      }
    }
    kept_memory(d, kept, processes.map(p => p.get("pgid").unwrap_or(Null)), memory => {
      let shown_connects = connects.map(c => connect_shown(d, c, sessions_of))
      let after_homes = () => {
        let profiles = match d.accounts {
          Some(a) => or_empty((a.profiles_view)(viewer))
          None => ja([])
        }
        let with_decisions = (decisions : J) => {
          disk_then(room => {
            let workspace = if viewer.home == Some(false) {
              Some(viewer.workspace)
            } else {
              None
            }
            let roots = roots_of(d, raw, workspace)
            let views : Array[J?] = roots.map(_ => None)
            let left = Ref(roots.length())
            let finish = () => {
              let mut viewer_shown = jo([("via", js("mesh"))])
              if viewer.raw is Obj(entries) {
                for e in entries {
                  viewer_shown = with_prop(
                    viewer_shown,
                    e.0,
                    e.1,
                  )
                }
              }
              let catalog = (d.catalog)()
              let count = (state : String) => {
                jn(states.filter(s => s == state).length().to_double())
              }
              let search_personal = match raw.get("search") {
                Some(s) => s.get("personal") is Some(Bool(true))
                None => false
              }
              let drive = jopt([
                ("roots", Some(ja(views.map(v => v.unwrap_or(Null))))),
                (
                  "anywhere",
                  if read_only(viewer.role) {
                    None
                  } else {
                    Some(Bool(true))
                  },
                ),
                (
                  "home",
                  if read_only(viewer.role) {
                    None
                  } else {
                    Some(js(d.homedir))
                  },
                ),
              ])
              let permissions = match d.permissions {
                Some(f) =>
                  match f(viewer) {
                    Some(Null) | None => None
                    Some(p) => Some(p)
                  }
                None => None
              }
              let built_at = match d.built_at {
                Some(ms) if ms > 0.0 && ms == ms.floor() && ms <= 9007199254740991.0 => Some(jn(ms))
                _ => None
              }
              done(
                Ok(
                  jopt([
                    ("builtAt", built_at),
                    ("automaticDecisions", Some(decisions)),
                    ("archiving", Some(archiving_view(raw, viewer))),
                    ("viewer", Some(viewer_shown)),
                    ("mesh", Some(mesh_status(d, Some(viewer)))),
                    ("connects", Some(ja(shown_connects))),
                    ("profiles", Some(profiles)),
                    ("sessionRuntimeChange", Some(Bool(true))),
                    ("connectRuntimeChange", Some(Bool(true))),
                    ("accountSubsets", Some(Bool(true))),
                    ("modelSpeeds", Some(Bool(true))),
                    ("claudeTui", Some(Bool(true))),
                    ("modelMakers", Some(model_makers(catalog, profiles))),
                    (
                      "contextCaps",
                      Some(
                        jo([
                          ("runtimes", ja([js("claude"), js("codex")])),
                          ("least", jn(100000.0)),
                          ("windows", model_windows(catalog, profiles)),
                        ]),
                      ),
                    ),
                    (
                      "processes",
                      Some(
                        ja(
                          processes.map(p => {
                            let kb = memory.get(
                              stringify(p.get("pgid").unwrap_or(Null)),
                            )
                            with_prop(
                              p,
                              "rssMb",
                              match kb {
                                Some(kb) => jn(js_round(kb / 1024.0))
                                None => Null
                              },
                            )
                          }),
                        ),
                      ),
                    ),
                    (
                      "counts",
                      Some(
                        jo([
                          ("sessions", jn(sessions_of(Some(Null)))),
                          ("running", count("running")),
                          ("warm", count("warm")),
                        ]),
                      ),
                    ),
                    ("slackUsers", Some((d.slack_identities)(viewer.email))),
                    ("disk", Some(room)),
                    (
                      "logins",
                      Some(
                        match d.accounts {
                          Some(a) => or_empty((a.logins_view)(viewer))
                          None => ja([])
                        },
                      ),
                    ),
                    (
                      "apiProviders",
                      Some(
                        match d.accounts {
                          Some(a) => or_empty((a.api_providers)())
                          None => ja([])
                        },
                      ),
                    ),
                    (
                      "machineLogins",
                      Some(
                        match d.accounts {
                          Some(a) => or_empty((a.machine_logins)())
                          None => ja([])
                        },
                      ),
                    ),
                    ("consoleSignIn", Some(Bool(d.accounts is Some(_)))),
                    ("sharing", Some(Bool(d.accounts is Some(_)))),
                    (
                      "updates",
                      Some(
                        match d.updates {
                          Some(u) => or_empty(u(lang))
                          None => ja([])
                        },
                      ),
                    ),
                    ("agentEnv", Some(agent_env_view(raw))),
                    ("context", Some(context_view(raw))),
                    ("diagnostics", Some(diagnostics_view(raw))),
                    ("network", Some(network_view(raw))),
                    ("drive", Some(drive)),
                    (
                      "search",
                      Some(
                        jo([
                          (
                            "files",
                            js(
                              if d.has_spotlight {
                                "spotlight"
                              } else {
                                "walk"
                              },
                            ),
                          ),
                          ("personal", Bool(search_personal)),
                        ]),
                      ),
                    ),
                    ("permissions", permissions),
                  ]),
                ),
              )
            }
            if roots.length() == 0 {
              return finish()
            }
            for i, root in roots {
              (d.root_view)(root, view => {
                views[i] = Some(view)
                left.val -= 1
                if left.val == 0 {
                  finish()
                }
              })
            }
          })
        }
        match d.accounts {
          Some(a) => decisions_view(d, a, kept, viewer, with_decisions)
          None => with_decisions(Null)
        }
      }
      match d.accounts {
        Some({ homes_read_soon: Some(soon), .. }) => soon(after_homes)
        _ => after_homes()
      }
    })
  }
  match (d.session_counts)(viewer, ids) {
    Some(counts) => counted(counts)
    None =>
      match d.wait_for_session_counts {
        None => done(Err("session counts are not ready"))
        Some(wait) =>
          wait(ready => {
            guard ready && (d.session_counts)(viewer, ids) is Some(counts) else {
              return done(Err("session counts are not ready"))
            }
            counted(counts)
          })
      }
  }
}

///|
/// A title not known yet, stood in for until its chat's name is read (overview.ts `pendingTitle`'s placeholder).
fn placeholder(session : String) -> String {
  placeholder_mark + session
}

///|
let placeholder_mark : String = "\u{F8FF}\u{0}title\u{0}"

///|
/// What has placeholders, with each the name read for it.
fn fill(value : J, names : Map[String, String]) -> J {
  match value {
    Str(s) => {
      let t = s
      if t.has_prefix(placeholder_mark) {
        match
          names.get(t.view(start_offset=placeholder_mark.length()).to_string()) {
          Some(name) => js(name)
          None => value
        }
      } else {
        value
      }
    }
    Arr(items) => Arr(items.map(i => fill(i, names)))
    Obj(entries) => Obj(entries.map(e => (e.0, fill(e.1, names))))
    other => other
  }
}

///|
/// overview.ts `madeDecisionsView`: none where the sessions it names are not ready.
fn made_decisions_view(
  d : OverviewDeps,
  a : AccountsDeps,
  viewer : Viewer,
  name : (String) -> String,
  visible : Map[String, Bool],
  checks : J?,
) -> J? {
  let mine = (session : J) => {
    guard session is Str(_) else { return false }
    let s = text_of(Some(session)).unwrap()
    match visible.get(s) {
      Some(b) => b
      None => {
        let b = sees(viewer, (d.session_ws)(s).unwrap_or(Null))
        visible[s] = b
        b
      }
    }
  }
  let titles : Map[String, String] = Map([])
  let title = (session : String) => {
    match titles.get(session) {
      Some(t) => t
      None => {
        let t = name(session)
        titles[session] = t
        t
      }
    }
  }
  guard (a.automatic_decisions_view)(viewer, mine, title) is Some(view) else {
    return None
  }
  if manages_station(viewer.role) {
    let ws = if viewer.home == Some(false) {
      js(viewer.workspace)
    } else {
      Null
    }
    let policy = (d.policy_view)(ws, mine, title, viewer, checks)
    Some(
      with_prop(with_prop(view, "policy", policy), "canEditPolicy", Bool(true)),
    )
  } else {
    Some(view)
  }
}

///|
/// The decisions' stamp: what makes them again when it changes.
fn decisions_stamp(d : OverviewDeps, a : AccountsDeps) -> String {
  decisions_stamp_of((d.decisions_version)(), (d.config)(), (a.decision_models)())
}

///|
fn decisions_stamp_of(decisions_version : J, config : J, decision_models : J) -> String {
  let automatic : J = match config.get("automaticDecisions") {
    None | Some(Null) => Null
    Some(v) => v
  }
  stringify(ja([decisions_version, automatic, decision_models]))
}

///|
/// Whose decisions a view is kept as: the viewer's role, home, workspace and email.
fn decisions_whose(viewer : Viewer) -> String {
  let home = match viewer.raw.get("home") {
    None => "undefined"
    Some(h) => @jsjson.js_string(h)
  }
  let workspace = match viewer.raw.get("workspace") {
    None | Some(Null) => ""
    Some(w) => @jsjson.js_string(w)
  }
  "\{viewer.role}\u{0}\{home}\u{0}\{workspace}\u{0}\{viewer.email}"
}

///|
/// Whether `decisions_view` would give the view it keeps for `viewer` at `now`, given these parts of its stamp: what
/// makes it (the accounts' automatic decisions, the archive policy's checks and view) need not be asked then.
pub fn OverviewKept::decisions_fresh(
  self : OverviewKept,
  viewer : Viewer,
  decisions_version : J,
  config : J,
  decision_models : J,
  now : Double,
) -> Bool {
  let stamp = decisions_stamp_of(decisions_version, config, decision_models)
  self.decisions.get(decisions_whose(viewer)) is Some((at, s, _)) &&
  s == stamp &&
  now - at < decisions_kept_ms
}

///|
/// overview.ts `decisionsView`: kept as made a while, made again once its stamp changes.
fn decisions_view(
  d : OverviewDeps,
  a : AccountsDeps,
  kept : OverviewKept,
  viewer : Viewer,
  done : (J) -> Unit,
) -> Unit {
  let stamp = decisions_stamp(d, a)
  let whose = decisions_whose(viewer)
  let now = (d.store_now)()
  if kept.decisions.get(whose) is Some((at, s, view)) &&
    s == stamp &&
    now - at < decisions_kept_ms {
    return done(view)
  }
  let again = () => decisions_view(d, a, kept, viewer, done)
  let made = (view : J) => {
    kept.decisions[whose] = ((d.store_now)(), stamp, view)
    done(view)
  }
  let with_checks = (checks : J?) => {
    match d.prepare_session_chat_names {
      None =>
        match made_decisions_view(d, a, viewer, d.chat_title, Map([]), checks) {
          None => (d.prepare_decision_sessions)(again)
          Some(view) => made(view)
        }
      Some(prepare_names) => {
        let placeholders : Map[String, Unit] = Map([])
        let pending = (session : String) => {
          placeholders[session] = ()
          placeholder(session)
        }
        let visible : Map[String, Bool] = Map([])
        match made_decisions_view(d, a, viewer, pending, visible, checks) {
          None => (d.prepare_decision_sessions)(again)
          Some(view) => {
            let names : Map[String, String] = Map([])
            fn look(waited : Bool) {
              let missing = []
              names.clear()
              if waited {
                for session, was in visible {
                  if sees(viewer, (d.session_ws)(session).unwrap_or(Null)) !=
                    was {
                    return again()
                  }
                }
              }
              for session, _ in placeholders {
                if !(d.session_there)(session) {
                  names[session] = (d.chat_title)(session)
                } else if !(d.chat_readable)(session) {
                  missing.push(session)
                } else {
                  names[session] = (d.chat_title)(session)
                }
              }
              if missing.length() > 0 {
                return prepare_names(missing, () => look(true))
              }
              let view = fill(view, names)
              if decisions_stamp(d, a) != stamp {
                return again()
              }
              made(view)
            }

            look(false)
          }
        }
      }
    }
  }
  match d.policy_checks {
    Some(checks_of) if manages_station(viewer.role) =>
      checks_of(now - view_days * 86_400_000.0, viewer, checks => {
        with_checks(
          match checks {
            Null => None
            c => Some(c)
          },
        )
      })
    _ => with_checks(None)
  }
}

///|
/// `v ?? []`.
fn or_empty(v : J) -> J {
  match v {
    Null => ja([])
    v => v
  }
}
