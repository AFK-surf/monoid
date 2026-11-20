// Every connect through the pages, whatever its kind (routes/connects.ts): a connect edited, deleted, pointed at a
// session, connected again; the config edits every connect's routes make (`ConnectEdits`: Slack's, Feishu's,
// Comma's and the group's routes add their own connects with them). What is a kind's own (its platform's part of a
// connect) is said by that kind's part: the station's (`connectKinds.get(kind).entry`) or the route file's own.

///|
/// How a kind's part of a connect is edited: from what was given and what it had, the part as it is to be kept
/// (None: none kept).
pub struct EntryEdit {
  edit : async (JV, JV) -> JV
}

///|
/// A field given as a string, trimmed and not empty (null when empty); whether it was given.
fn connect_field(object : JV?, key : String) -> (Bool, String?) {
  match field_of(object, key) {
    None => (false, None)
    Some(v) => {
      let t = match v {
        Str(s) => trim_js(s)
        _ => ""
      }
      (true, if t == "" { None } else { Some(t) })
    }
  }
}

///|
/// A connect id from its bot's name: lower case, runs of anything else as one dash.
pub fn connect_slug(name : String, fallback~ : String = "slack") -> String {
  let out = StringBuilder::new()
  let mut last_dash = false
  for c in points(@jscase.lower(name)) {
    let u = c.unsafe_charcode_at(0)
    if c.length() == 1 && ((u >= 'a' && u <= 'z') || (u >= '0' && u <= '9')) {
      out.write_string(c)
      last_dash = false
    } else if !last_dash {
      out.write_char('-')
      last_dash = true
    }
  }
  let s = out.to_string()
  // trim dashes at both ends, at most 32, no dash at its end
  let mut a = 0
  let mut b = s.length()
  while a < b && s.unsafe_charcode_at(a) == '-' {
    a += 1
  }
  while b > a && s.unsafe_charcode_at(b - 1) == '-' {
    b -= 1
  }
  let mut slug = chars(s.unsafe_substring(start=a, end=b), 32)
  while slug.has_suffix("-") {
    slug = slug.unsafe_substring(start=0, end=slug.length() - 1)
  }
  if slug == "" {
    fallback
  } else {
    slug
  }
}

///|
fn viewer_name(r : Request) -> String {
  let n = r.who_str("name")
  if n == "" {
    r.email()
  } else {
    n
  }
}

///|
fn has_space(s : String) -> Bool {
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    if space_ranges.iter().any(r => c >= r.0 && c <= r.1) {
      return true
    }
  }
  false
}

///|
/// Who a connect belongs to: whoever added it, unless `requested` hands it to someone else.
fn Admin::owner_of(
  self : Admin,
  current : JV,
  requested : JV?,
  r : Request,
) -> JV raise Thrown {
  guard requested is Some(requested) else {
    return if current is Obj(_) {
      current
    } else {
      jobj([("id", js(r.email())), ("name", js(viewer_name(r)))])
    }
  }
  let id = match field_of(Some(requested), "id") {
    Some(Str(s)) => @jscase.lower(trim_js(s))
    _ => ""
  }
  let email = match id.find("@") {
    Some(at) => {
      let a = id.unsafe_substring(start=0, end=at)
      let b = id.unsafe_substring(start=at + 1, end=id.length())
      a != "" && b != "" && !has_space(id) && !b.contains("@")
    }
    None => false
  }
  if id != "local" && !email {
    raise Thrown(
      "Error",
      jobj([("message", js(self.tr(r.lang, "station.connect.ownerEmail")))]),
    )
  }
  if !manages_station(r.viewer) &&
    (!(current is Obj(_)) || current.get("id") != Some(js(r.email()))) {
    raise Thrown(
      "Error",
      jobj([("message", js(self.tr(r.lang, "station.connect.ownerWho")))]),
    )
  }
  let name = match field_of(Some(requested), "name") {
    Some(Str(n)) => chars(n, 120)
    _ => id
  }
  jobj([("id", js(id)), ("name", js(name))])
}

///|
/// Bare station id from either a bare id ("st2") or a `<workspace>/<station_id>` address ("ws1/st2").
fn bare_station_id(s : String) -> String {
  let t = trim_js(s)
  match t.rev_find("/") {
    Some(i) => trim_js(t.unsafe_substring(start=i + 1, end=t.length()))
    None => t
  }
}

///|
fn station_list_of(v : JV?) -> Array[String]? {
  guard v is Some(Arr(items)) else { return None }
  let out = []
  for x in items {
    match x {
      Str(s) => {
        let t = bare_station_id(s)
        if t != "" && !out.contains(t) {
          out.push(t)
        }
      }
      _ => ()
    }
  }
  if out.length() > 0 {
    Some(out)
  } else {
    None
  }
}

///|
/// A list of profile ids: each once, trimmed, none empty; None where it is no list or comes to none.
fn list_of(v : JV?) -> Array[String]? {
  guard v is Some(Arr(items)) else { return None }
  let out = []
  for x in items {
    match x {
      Str(s) if trim_js(s) != "" => {
        let t = trim_js(s)
        if !out.contains(t) {
          out.push(t)
        }
      }
      _ => ()
    }
  }
  if out.length() > 0 {
    Some(out)
  } else {
    None
  }
}

///|
fn error_thrown(message : String) -> Thrown {
  Thrown("Error", jobj([("message", js(message))]))
}

///|
/// The config edits of the connects' routes, for one kind's entry (`entry`).
priv struct ConnectEdits {
  admin : Admin
  entry : async (String) -> EntryEdit?
}

///|
fn Admin::connect_edits(
  self : Admin,
  entry : async (String) -> EntryEdit?,
) -> ConnectEdits {
  { admin: self, entry, }
}

///|
/// The station's own kinds (connects/connections.ts `ConnectKind`): a kind's part edited as it says.
async fn Admin::station_entry(self : Admin, kind : String) -> EntryEdit? {
  match ref_of(self.backend.ask("connectKinds.get", [js(kind)])) {
    Some(part) => {
      let name = part + ".entry"
      Some({
        edit: async fn(given, had) { self.backend.ask(name, [given, had]) },
      })
    }
    None => None
  }
}

///|
async fn ConnectEdits::raw(self : ConnectEdits) -> JV {
  self.admin.config_raw()
}

///|
/// `Array.isArray(raw().connects) ? raw().connects : []`: config.json read as often as the station reads it.
async fn ConnectEdits::listed(self : ConnectEdits) -> Array[JV] {
  if self.raw().get("connects") is Some(Arr(_)) {
    jitems(self.raw().get("connects"))
  } else {
    []
  }
}

///|
fn connects_of(raw : JV) -> Array[JV] {
  jitems(raw.get("connects"))
}

///|
/// Where the station is in still.fail cloud: its workspace (None: none said, the home one's connects say none).
async fn ConnectEdits::home(self : ConnectEdits) -> JV {
  let place = self.admin.backend.ask("agents.place", [])
  if nullish(place) {
    return Null
  }
  match place.get("workspace") {
    Some(w) if !nullish(w) => w
    _ => Null
  }
}

///|
/// A connect is of the workspace it was added in, and only that workspace's people see and change it.
async fn ConnectEdits::of_viewer(
  self : ConnectEdits,
  r : Request,
  c : JV?,
) -> Bool {
  let home = self.home()
  if home is Null {
    return true
  }
  let ws = match field_of(c, "workspace") {
    Some(Str(w)) if w != "" => js(w)
    _ => self.home()
  }
  ws == r.who("workspace").unwrap_or(jundef)
}

///|
fn id_is(c : JV, id : String) -> Bool {
  field_of(Some(c), "id") == Some(js(id))
}

///|
async fn ConnectEdits::mine(
  self : ConnectEdits,
  r : Request,
  id : String,
) -> String {
  let c = self.listed().iter().find_first(c => id_is(c, id))
  match c {
    Some(c) if !self.of_viewer(r, Some(c)) =>
      raise Refused(404, "unknown connect \{id}")
    _ => ()
  }
  id
}

///|
/// Edits the config for the viewer (said in the log as `what`); its refusals are the asker's (400).
async fn ConnectEdits::change(
  self : ConnectEdits,
  r : Request,
  what : String,
  edit : async (JV) -> JV,
) -> Unit {
  try {
    let raw = self.admin.config_raw()
    let next = edit(raw)
    self.admin.backend.tell("config.updateSoon", [next])
  } catch {
    Refused(_) as e => raise e
    e => raise Refused(400, message_of(e))
  }
  self.admin.log(
    "info",
    "admin",
    "config changed from the admin page",
    jobj([("what", js(what)), ("by", js(r.email()))]),
  )
}

///|
async fn ConnectEdits::save(
  self : ConnectEdits,
  r : Request,
  what : String,
  edit : async (JV) -> JV,
) -> JV {
  self.change(r, what, edit)
  self.admin.overview_of(r)
}

///|
/// `connectsRaw(raw)`: its connects, made a list where it was none.
fn with_connects(raw : JV) -> JV {
  if raw.get("connects") is Some(Arr(_)) {
    raw
  } else {
    jset(raw, "connects", jarr([]))
  }
}

///|
/// A connect added or edited: its kind's part as `entry` makes it; another runtime, model, effort or profile reaches
/// a single-session connect's session too, from its next turn on.
async fn ConnectEdits::put_connect(
  self : ConnectEdits,
  r : Request,
  id : String,
  i : JV,
) -> JV {
  let a = self.admin
  let lang = r.lang
  // A connect runs on one station of its workspace: one added here that runs on another already is refused.
  let adding = !self.listed().iter().any(c => id_is(c, id))
  let added_kind = jstr(i.get("kind")).unwrap_or("slack")
  if adding && a.setup.has("agents.heldBy") {
    let ws = match r.who("workspace") {
      Some(w) if is_truthy(Some(w)) => w
      _ => self.home()
    }
    let own = match (self.entry)(added_kind) {
      Some(e) => {
        let o = (e.edit)(i.get(added_kind).unwrap_or(jundef), Null)
        if nullish(o) {
          JV::Null
        } else {
          o
        }
      }
      None => Null
    }
    let held = a.backend.ask("agents.heldBy", [ws, js(added_kind), own])
    if !(held is Null) {
      raise Refused(
        409,
        a.tr(lang, "station.connect.heldElsewhere", args=[
          ("station", js_string(Some(held))),
        ]),
      )
    }
  }
  let follow : Ref[(String, JV)?] = Ref(None)
  self.change(r, "connect \{id}", async fn(raw) {
    let raw = with_connects(raw)
    let connects = connects_of(raw)
    let existing = connects.iter().find_first(c => id_is(c, id))
    match existing {
      Some(e) if !self.of_viewer(r, Some(e)) =>
        raise Refused(404, "unknown connect \{id}")
      _ => ()
    }
    let bind = i.get("bind")
    let old_bind = match field_of(existing, "bind") {
      Some(Obj(_) as b) => Some(b)
      _ => None
    }
    let given = field_of(bind, "runtime")
    let was = match old_bind {
      None => None
      Some(b) => {
        let k = a.backend.ask("agents/runtime.runtimeKind", [
          b.get("runtime").unwrap_or(jundef),
        ])
        Some(if is_undef(k) { js("claude") } else { k })
      }
    }
    let runtime = match given {
      Some(g) => {
        let named = a.backend.ask("agents/runtime.runtimeKind", [g])
        if is_undef(named) {
          raise error_thrown(
            "unknown runtime \{match g { Str(s) => s; _ => stringify(g) }}",
          )
        }
        named
      }
      None =>
        match was {
          Some(w) => w
          None => raise error_thrown("runtime is required")
        }
    }
    let moved = match was {
      Some(w) => w != runtime
      None => false
    }
    // (what went with the old runtime is not kept on another)
    let kept = (key : String) => {
      let (given, value) = connect_field(bind, key)
      if given {
        value
      } else if !moved {
        jstr(field_of(old_bind, key))
      } else {
        None
      }
    }
    let model = kept("model")
    let effort = kept("effort")
    let old_profiles = match list_of(field_of(old_bind, "profiles")) {
      Some(l) => Some(l)
      None =>
        match field_of(old_bind, "profile") {
          Some(Str(p)) if p != "" => Some([p])
          _ => None
        }
    }
    let raw_profiles = field_of(bind, "profiles")
    match raw_profiles {
      None | Some(Null) => ()
      Some(Arr(items)) if items.all(x => x is Str(_)) => ()
      _ => raise Refused(400, "profiles must be a list of profile ids or null")
    }
    let (profile_given, profile_value) = connect_field(bind, "profile")
    let profiles = if raw_profiles is Some(_) {
      list_of(raw_profiles)
    } else if profile_given {
      profile_value.map(p => [p])
    } else if !moved {
      old_profiles
    } else {
      None
    }
    let runtime_name = js_string(Some(runtime))
    if moved {
      let all = jitems(a.hub("config", []).get("profiles"))
      let available = all.filter(p => {
        !(p.get("enabled") is Some(Bool(false))) &&
        jitems(p.get("runtimes")).contains(runtime)
      })
      if available.length() == 0 {
        let title = js_string(
          Some(a.backend.ask("sessions/config.runtimeTitle", [runtime])),
        )
        raise error_thrown(
          a.tr(lang, "station.session.noProfileHere", args=[("runtime", title)]),
        )
      }
      match model {
        Some(m) => {
          let mut any = false
          for p in available {
            if is_truthy(
                Some(a.backend.ask("sessions/config.runs", [p, js(m)])),
              ) {
              any = true
              break
            }
          }
          if !any {
            let title = js_string(
              Some(a.backend.ask("sessions/config.runtimeTitle", [runtime])),
            )
            raise error_thrown(
              a.tr(lang, "station.session.noProfileForModel", args=[
                ("model", m),
                ("runtime", title),
              ]),
            )
          }
        }
        None => ()
      }
    }
    // The profile(s) its sessions keep to (null: the pool's pick), each running its runtime and model.
    match profiles {
      Some(list) => {
        let all = jitems(a.hub("config", []).get("profiles"))
        let explicit = moved ||
          raw_profiles is Some(_) ||
          field_of(bind, "profile") is Some(_)
        for pid in list {
          let p = all.iter().find_first(x => x.get("id") == Some(js(pid)))
          match p {
            Some(p) if jitems(p.get("runtimes")).contains(runtime) => {
              if p.get("enabled") is Some(Bool(false)) && explicit {
                raise error_thrown(
                  a.tr(lang, "station.profile.disabled", args=[
                    ("profile", js_string(p.get("name"))),
                  ]),
                )
              }
              match model {
                Some(m) =>
                  if !is_truthy(
                      Some(a.backend.ask("sessions/config.runs", [p, js(m)])),
                    ) {
                    raise error_thrown(
                      a.tr(lang, "station.profile.modelOff", args=[
                        ("profile", js_string(p.get("name"))),
                        ("model", m),
                      ]),
                    )
                  }
                None => ()
              }
            }
            _ =>
              raise error_thrown(
                a.tr(lang, "station.profile.cannotRun", args=[
                  ("profile", pid),
                  ("runtime", runtime_name),
                ]),
              )
          }
        }
      }
      None => ()
    }
    match effort {
      Some(e) if moved ||
        ["model", "effort", "profile", "profiles"]
        .iter()
        .any(f => field_of(bind, f) is Some(_)) => {
        let allowed = a.backend.ask("hub.accounts.modelEfforts", [
          runtime,
          jopt(model),
          match profiles {
            Some(l) => jstrs(l)
            None => Null
          },
        ])
        if !is_undef(allowed) && !jitems(Some(allowed)).contains(js(e)) {
          let sep = a.tr(lang, "station.list.separator")
          let efforts = jitems(Some(allowed))
            .map(x => {
              match x {
                Null => ""
                _ => js_string(Some(x))
              }
            })
            .join(sep)
          raise error_thrown(
            a.tr(lang, "station.profile.efforts", args=[
              ("runtime", runtime_name),
              ("efforts", efforts),
            ]),
          )
        }
      }
      _ => ()
    }
    let mut next = jobj([("id", js(id))])
    let current_owner = match field_of(existing, "createdBy") {
      Some(o) if !nullish(o) => o
      _ => Null
    }
    let owner = a.owner_of(current_owner, i.get("owner"), r)
    next = jset(
      next,
      "enabled",
      match (i.get("enabled"), field_of(existing, "enabled")) {
        (Some(Bool(b)), _) => jbool(b)
        (_, Some(Bool(b))) => jbool(b)
        _ => jbool(true)
      },
    )
    let kind = match (i.get("kind"), field_of(existing, "kind")) {
      (Some(Str(k)), _) => k
      (_, Some(Str(k))) => k
      _ => "slack"
    }
    next = jset(next, "kind", js(kind))
    next = jset(
      next,
      "mode",
      match (i.get("mode"), field_of(existing, "mode")) {
        (Some(Str("multi-session" | "single-session") as m), _) => m
        (_, Some(Str("multi-session" | "single-session") as m)) => m
        _ => js("multi-session")
      },
    )
    next = jset(
      next,
      "requireMention",
      match (i.get("requireMention"), field_of(existing, "requireMention")) {
        (Some(Bool(b)), _) => jbool(b)
        (_, Some(Bool(b))) => jbool(b)
        _ => jbool(true)
      },
    )
    // Its kind's own part (its platform's tokens or app, who it is there): from what was given, and what it had.
    match (self.entry)(kind) {
      Some(edit) => {
        let had = match field_of(existing, kind) {
          Some(Obj(_) as o) => o
          _ => Null
        }
        let own = (edit.edit)(i.get(kind).unwrap_or(jundef), had)
        if !(own is Null) {
          next = jset(next, kind, own)
        }
      }
      None => ()
    }
    if !(owner is Null) {
      next = jset(next, "createdBy", owner)
    }
    // The station(s) of its workspace a new conversation of it runs on; absent: this one.
    // `stations` is an explicit manual allowlist: [] clears both; [s] writes `station` alone; >=2 writes `stations`
    // and sets `station` to its first entry so older clients still read `startsOn`.
    let raw_auto = i.get("autoStation")
    match raw_auto {
      None | Some(Null) | Some(Bool(_)) => ()
      _ => raise Refused(400, "autoStation must be a boolean or null")
    }
    let raw_stations = i.get("stations")
    match raw_stations {
      None | Some(Null) => ()
      Some(Arr(items)) if items.all(x => x is Str(_)) => ()
      _ => raise Refused(400, "stations must be a list of station ids or null")
    }
    let old_auto = field_of(existing, "autoStation") is Some(Bool(true))
    let old_stations : Array[String] = if old_auto {
      []
    } else {
      match station_list_of(field_of(existing, "stations")) {
        Some(l) => l
        None =>
          match field_of(existing, "station") {
            Some(Str(s)) if bare_station_id(s) != "" => [bare_station_id(s)]
            _ => []
          }
      }
    }
    if raw_auto is Some(Bool(true)) {
      next = jset(next, "autoStation", jbool(true))
    } else if raw_stations is Some(_) {
      match station_list_of(raw_stations) {
        Some([s]) => next = jset(next, "station", js(s))
        Some(l) if l.length() > 1 => {
          next = jset(next, "stations", jstrs(l))
          next = jset(next, "station", js(l[0]))
        }
        _ => ()
      }
    } else if i.get("station") is Some(st) {
      match st {
        Str(s) if bare_station_id(s) != "" => next = jset(next, "station", js(bare_station_id(s)))
        _ => ()
      }
    } else if raw_auto is Some(Bool(false)) {
      // Explicit opt-out of autoStation with no manual stations specified: defaults to running here.
      ()
    } else if old_auto {
      next = jset(next, "autoStation", jbool(true))
    } else {
      let mut has_station = false
      match field_of(existing, "station") {
        Some(Str(s)) if bare_station_id(s) != "" => {
          next = jset(next, "station", js(bare_station_id(s)))
          has_station = true
        }
        _ => ()
      }
      match station_list_of(field_of(existing, "stations")) {
        Some(l) if l.length() > 1 => {
          next = jset(next, "stations", jstrs(l))
          if !has_station {
            next = jset(next, "station", js(l[0]))
          }
        }
        Some([s]) if !has_station => next = jset(next, "station", js(s))
        _ => ()
      }
    }
    let next_auto = next.get("autoStation") is Some(Bool(true))
    let next_stations : Array[String] = if next_auto {
      []
    } else {
      match station_list_of(next.get("stations")) {
        Some(l) => l
        None =>
          match next.get("station") {
            Some(Str(s)) if bare_station_id(s) != "" => [bare_station_id(s)]
            _ => []
          }
      }
    }
    let routing_changed = match existing {
      None => next_auto || next_stations.length() > 0
      Some(_) => old_auto != next_auto || old_stations != next_stations
    }
    if routing_changed && !manages_station(r.viewer) {
      raise Refused(403, a.tr(lang, "station.connect.stationManagersOnly"))
    }
    // Added in a workspace the station joined: that workspace's.
    if existing is None {
      let home = self.home()
      if !(home is Null) && r.who("workspace").unwrap_or(jundef) != self.home() {
        next = jset(next, "workspace", r.who("workspace").unwrap_or(jundef))
      }
    }
    let mut b = jobj([("runtime", runtime)])
    match model {
      Some(m) => b = jset(b, "model", js(m))
      None => ()
    }
    match effort {
      Some(e) => b = jset(b, "effort", js(e))
      None => ()
    }
    match profiles {
      Some([p]) => b = jset(b, "profile", js(p))
      Some(l) if l.length() > 1 => b = jset(b, "profiles", jstrs(l))
      _ => ()
    }
    next = jset(next, "bind", b)
    // (checked before it is saved: a model its session cannot run is refused for both)
    let bound = match old_bind {
      Some(_) if next.get("mode") == Some(js("single-session")) =>
        a.backend.ask("hub.store.binding", [js(id)])
      _ => Null
    }
    if !(bound is Null) {
      let old = old_bind.unwrap()
      let profile_change = () => {
        match profiles {
          None => [("profile", JV::Null), ("profiles", JV::Null)]
          Some([p]) => [("profile", js(p)), ("profiles", jstrs([p]))]
          Some(l) => [("profiles", jstrs(l))]
        }
      }
      let mut run = if moved {
        jobj(
          [
            ("runtime", runtime),
            ("model", jopt(model)),
            ("effort", jopt(effort)),
          ] +
          profile_change(),
        )
      } else {
        Obj([])
      }
      let differs = (key : String) => {
        !moved &&
        (match old.get(key) {
          Some(v) if !nullish(v) => v
          _ => Null
        }) !=
        (match b.get(key) {
          Some(v) if !nullish(v) => v
          _ => Null
        })
      }
      if differs("model") {
        run = jset(run, "model", jopt(model))
      }
      if differs("model") || differs("effort") {
        run = jset(run, "effort", jopt(effort))
      }
      let shown = (l : Array[String]?) => {
        match l {
          Some(l) => stringify(jstrs(l))
          None => "null"
        }
      }
      if !moved && shown(old_profiles) != shown(profiles) {
        for f in profile_change() {
          run = jset(run, f.0, f.1)
        }
      }
      if jfields(Some(run)).length() > 0 {
        a.backend.tell("hub.accounts.change", [bound, run, js(lang)])
        follow.val = Some((js_string(Some(bound)), run))
      }
    }
    // What this station does not know of it is kept (but its kind's part, and the part of a kind it was).
    let was_kind = match field_of(existing, "kind") {
      Some(Str(k)) => k
      _ => "slack"
    }
    let known = [
      "id", "enabled", "kind", "mode", "requireMention", "createdBy", "bind", "station", "stations", "autoStation",
      kind, was_kind,
    ]
    for f in jfields(existing) {
      if !known.contains(f.0) {
        next = jset(next, f.0, f.1)
      }
    }
    let mut placed = false
    let out = connects.map(c => {
      if !placed && id_is(c, id) {
        placed = true
        next
      } else {
        c
      }
    })
    if !placed {
      out.push(next)
    }
    jset(raw, "connects", jarr(out))
  })
  match follow.val {
    Some((session, run)) => {
      a.backend.tell("sessions/lifecycle.configure", [
        jref("hub"),
        js(session),
        run,
        js(lang),
      ])
      a.log(
        "info",
        "admin",
        "single-session connect's session follows its run",
        jobj([("connect", js(id)), ("session", js(session))]),
      )
    }
    None => ()
  }
  a.overview_of(r)
}

///|
/// An answer of the connects' routes: a Refused as it is, anything else logged and a 500.
async fn Admin::connect_answer(
  self : Admin,
  r : Request,
  f : async () -> Answer,
) -> Answer {
  f() catch {
    e =>
      match refused_of(e) {
        Some((status, message)) => error(status, message)
        None => {
          self.log(
            "error",
            "admin",
            "admin request failed",
            jobj([("path", js(r.path)), ("error", js(message_of(e)))]),
          )
          error(500, message_of(e))
        }
      }
  }
}

///|
/// The routes of every connect: PUT and DELETE /connects/:id, POST /connects/:id/session and /reconnect.
fn Admin::connect_routes(self : Admin) -> Array[Route] {
  let edits = self.connect_edits(async fn(kind) { self.station_entry(kind) })
  let answer = (f : async (Request, Array[String?]) -> Answer) => {
    async fn(r : Request, m : Array[String?]) -> Answer {
      self.connect_answer(r, async fn() { f(r, m) })
    }
  }
  [
    route(
      "PUT",
      "^\\/*connects\\/+([^/]+)\\/*$",
      answer(async fn(r, m) {
        let id = edits.mine(r, segment(m[0].unwrap()))
        ok(edits.put_connect(r, id, input(r)))
      }),
    ),
    route(
      "DELETE",
      "^\\/*connects\\/+([^/]+)\\/*$",
      answer(async fn(r, m) {
        let id = edits.mine(r, segment(m[0].unwrap()))
        ok(
          edits.save(r, "delete connect \{id}", async fn(raw) {
            let raw = with_connects(raw)
            let connects = connects_of(raw)
            if !connects.iter().any(c => id_is(c, id)) {
              raise error_thrown("unknown connect \{id}")
            }
            jset(raw, "connects", jarr(connects.filter(c => !id_is(c, id))))
          }),
        )
      }),
    ),
    route(
      "POST",
      "^\\/*connects\\/+([^/]+)\\/+session(?:\\/.*)?$",
      answer(async fn(r, m) {
        let id = edits.mine(r, segment(m[0].unwrap()))
        let i = input(r)
        let target = match i.get("session") {
          Some(Str(s)) if s != "" => js(s)
          _ => Null
        }
        if !self.setup.has("agents") {
          raise Refused(503, "station starting")
        }
        let key = self.backend.ask("sessions/lifecycle.bindSingle", [
          jref("hub"),
          js(id),
          target,
          match i.get("title") {
            Some(Str(_) as t) => t
            _ => Null
          },
          js(r.email()),
        ])
        self.log(
          "info",
          "admin",
          "single-session binding changed from the admin page",
          jobj([("connect", js(id)), ("session", key), ("by", js(r.email()))]),
        )
        ok(jobj([("session", key)]))
      }),
    ),
    route(
      "POST",
      "^\\/*connects\\/+([^/]+)\\/+reconnect(?:\\/.*)?$",
      answer(async fn(r, m) {
        let id = edits.mine(r, segment(m[0].unwrap()))
        let kind = match edits.listed().iter().find_first(c => id_is(c, id)) {
          Some(c) =>
            match c.get("kind") {
              Some(Str(k)) => k
              _ => "slack"
            }
          None => "slack"
        }
        match ref_of(self.backend.ask("connectKinds.get", [js(kind)])) {
          Some(part) => self.backend.tell(part + ".reconnect", [js(id)])
          None => ()
        }
        ok(jobj([("ok", jbool(true))]))
      }),
    ),
  ]
}
