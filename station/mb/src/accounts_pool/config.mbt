// What the accounts read of config.json, as station/src/sessions/config.ts has it (`hubConfig`'s profiles, connects
// and automatic decisions; `spelling`, `runs`, `allowedIn`): a profile stays config.json's object (what the drivers
// and the parts asked read of it), its home made absolute and what parse_config derives added.

///|
/// A profile as `hubConfig` makes it: `raw` the object itself (passed whole to the parts that are asked about it),
/// and what is read of it most.
pub(all) struct Profile {
  raw : JV
  id : String
  name : String
  runtime : String?
  service : String?
  runtimes : Array[String]
  models : Array[String]
  named : Array[String]
  model : String?
  home : String
  enabled : Bool
  machine : Bool
  background_on_message : Bool
  withheld : Array[String]?
}

///|
pub fn Profile::get(self : Profile, k : String) -> JV? {
  self.raw.get(k)
}

///|
pub(all) struct Connect {
  raw : JV
  id : String
  workspace : String?
  runtime : String
  model : String?
  bot_name : String?
}

///|
pub(all) struct HubConfig {
  profiles : Array[Profile]
  connects : Array[Connect]
  completion_enabled : Bool
  completion_model : String?
}

///|
/// Node's `path.isAbsolute` (POSIX).
fn is_absolute(p : String) -> Bool {
  p.has_prefix("/")
}

///|
/// Node's `path.normalize` (POSIX).
pub fn normalize_path(path : String) -> String {
  @nodepath.join("/", [path])
}

///|
/// Node's `path.join` (POSIX).
pub fn join_path(parts : Array[String]) -> String {
  @nodepath.join("/", parts)
}

///|
fn under(data : String, path : String) -> String {
  if is_absolute(path) {
    path
  } else {
    join_path([data, path])
  }
}

///|
/// A profile on the machine's login as it was named before, without the "this machine" it was said with.
fn machine_name(name : String) -> String {
  let mut n = name
  if n.has_suffix("（本机）") {
    n = slice(n, 0, b=n.length() - "（本机）".length())
  } else if n.has_suffix(" (local)") {
    n = slice(n, 0, b=n.length() - " (local)".length())
  }
  if n.has_prefix("本机 ") {
    n = slice(n, "本机 ".length())
  } else if n.has_prefix("Local ") {
    n = slice(n, "Local ".length())
  }
  n
}

///|
fn str_of(v : JV?) -> String? {
  match v {
    Some(Str(s)) => Some(s)
    _ => None
  }
}

///|
/// One profile as `hubConfig` makes it. `found`: the models its last check found.
pub fn profile_of(
  p : JV,
  data : String,
  found : (String) -> Array[String]?,
) -> Profile {
  let seen : Map[String, Unit] = {}
  let models : Array[String] = []
  for m in jitems(p.get("models")) {
    let t = trim_js(js_string(Some(m)))
    if t != "" && !seen.contains(t) {
      seen[t] = ()
      models.push(t)
    }
  }
  let home_text = match p.get("home") {
    None | Some(Null) => ""
    v => js_string(v)
  }
  let home = under(data, home_text)
  let base = jset(p, "home", js(home))
  let runtimes = profile_runtimes(base)
  let runs = models.copy()
  let id_text = js_string(p.get("id"))
  if runtimes.length() > 0 {
    let has : Map[String, Unit] = {}
    for m in models {
      has[model_key(m)] = ()
    }
    for m in found(id_text).unwrap_or([]) {
      if m == "" || has.contains(model_key(m)) {
        continue
      }
      has[model_key(m)] = ()
      runs.push(m)
    }
  }
  let machine = p.get("machine") == Some(Bool(true))
  let given = str_of(p.get("name")).map(n => if machine { machine_name(n) } else { n })
  let name_v : JV = match given {
    Some(n) if trim_js(n) != "" => Str(trim_js(n))
    _ => p.get("id").unwrap_or(jundef)
  }
  let runtime : String? = if runtimes.length() > 0 { Some(runtimes[0]) } else { None }
  let service = profile_service(base)
  let model = nonempty_str(p.get("model"))
  let withheld = match p.get("withheld") {
    Some(Arr(a)) =>
      Some(
        a.filter_map(w => match w {
          Str(s) if s != "" => Some(s)
          _ => None
        }),
      )
    _ => None
  }
  let mut o = base
  o = jset(o, "id", p.get("id").unwrap_or(jundef))
  o = if is_undef(name_v) { jdel(o, "name") } else { jset(o, "name", name_v) }
  o = match runtime {
    Some(r) => jset(o, "runtime", js(r))
    None => jdel(o, "runtime")
  }
  o = match service {
    Some(s) => jset(o, "service", js(s))
    None => jdel(o, "service")
  }
  o = jset(o, "runtimes", jstrs(runtimes))
  o = jset(o, "models", jstrs(runs))
  o = jset(o, "named", jstrs(models))
  o = match model {
    Some(m) => jset(o, "model", js(m))
    None => jdel(o, "model")
  }
  let bg = p.get("backgroundOnMessage") != Some(Bool(false))
  o = jset(o, "backgroundOnMessage", jbool(bg))
  let enabled = p.get("enabled") != Some(Bool(false))
  o = jset(o, "enabled", jbool(enabled))
  o = match withheld {
    Some(w) => jset(o, "withheld", jstrs(w))
    None => o
  }
  if is_undef(o.get("id").unwrap_or(Null)) {
    o = jdel(o, "id")
  }
  {
    raw: o,
    id: id_text,
    name: match name_v {
      Str(s) => s
      other => js_string(defined(other))
    },
    runtime,
    service,
    runtimes,
    models: runs,
    named: models,
    model,
    home,
    enabled,
    machine,
    background_on_message: bg,
    withheld,
  }
}

///|
/// config.json (parsed) as the hub reads it (`hubConfig`): its profiles, connects and automatic decisions.
pub fn hub_config(
  raw : JV,
  data : String,
  found? : (String) -> Array[String]? = _ => None,
) -> HubConfig {
  let profiles = jitems(raw.get("profiles")).map(p => profile_of(p, data, found))
  let connects = jitems(raw.get("connects")).map(c => {
    let bind = c.get("bind").unwrap_or(Obj([]))
    let slack = c.get("slack")
    {
      raw: c,
      id: js_string(c.get("id")),
      workspace: nonempty_str(c.get("workspace")),
      runtime: runtime_kind(bind.get("runtime")).unwrap_or("claude"),
      model: nonempty_str(bind.get("model")),
      bot_name: nonempty_str(jget(slack, "botName")),
    }
  })
  let completion = jget(raw.get("automaticDecisions"), "completion")
  {
    profiles,
    connects,
    completion_enabled: jget(completion, "enabled") == Some(Bool(true)),
    completion_model: str_of(jget(completion, "model")),
  }
}

///|
/// `spelling`: its own spelling of a model it runs, however the model is spelled.
pub fn spelling(p : Profile, model : String) -> String? {
  match p.models.iter().find_first(m => m == model) {
    Some(m) => return Some(m)
    None => ()
  }
  match p.models.iter().find_first(m => same_model(m, model)) {
    Some(m) => return Some(m)
    None => ()
  }
  if p.runtimes.contains("agy") {
    let base = agy_base_model(model)
    return p.models
      .iter()
      .find_first(m => m == base || same_model(m, base) || agy_base_model(m) == base)
  }
  if p.runtimes.contains("devin") {
    match devin_fusion_split(model) {
      Some((lead, _, side)) => {
        let base = "fusion-\{lead}-sidekick-\{side}"
        let found = p.models
          .iter()
          .find_first(m => m == base || same_model(m, base) || devin_fusion_base(m) == base)
        if found is Some(_) {
          return Some(base)
        }
        if p.models.iter().any(m => m == lead || same_model(m, lead)) {
          return Some(base)
        }
      }
      None => ()
    }
  }
  None
}

///|
/// `runs`: whether it runs a model, in any spelling.
pub fn runs(p : Profile, model : String) -> Bool {
  spelling(p, model) is Some(_)
}

///|
/// `allowedIn`: whether sessions of workspace `ws` (None: the home one's) may run on a profile.
pub fn allowed_in(p : Profile, ws : String?, home : String?) -> Bool {
  let share = p.get("share")
  let only = if jget(share, "borrowed") == Some(Bool(true)) {
    match jget(share, "workspaces") {
      Some(Arr(a)) => Some(a)
      _ => None
    }
  } else {
    None
  }
  let at = match ws {
    Some(_) => ws
    None => home
  }
  match (only, at) {
    (Some(list), Some(a)) if !list.contains(Str(a)) => return false
    _ => ()
  }
  match (ws, home) {
    (None, _) | (_, None) => true
    (Some(w), Some(h)) =>
      w == h || !p.withheld.unwrap_or([]).contains(w)
  }
}

///|
/// A profile as `hubConfig` made it already (one given whole, as the TypeScript passes its profiles around).
pub fn Profile::of_hub(v : JV) -> Profile {
  let strings = (k : String) => jitems(v.get(k)).map(x => js_string(Some(x)))
  {
    raw: v,
    id: js_string(v.get("id")),
    name: match v.get("name") {
      Some(Str(n)) => n
      other => js_string(other)
    },
    runtime: runtime_kind(v.get("runtime")),
    service: match nonempty_str(v.get("service")) {
      Some(s) => Some(s)
      None => profile_service(v)
    },
    runtimes: strings("runtimes"),
    models: strings("models"),
    named: strings("named"),
    model: nonempty_str(v.get("model")),
    home: js_string(v.get("home")),
    enabled: v.get("enabled") != Some(Bool(false)),
    machine: v.get("machine") == Some(Bool(true)),
    background_on_message: v.get("backgroundOnMessage") != Some(Bool(false)),
    withheld: match v.get("withheld") {
      Some(Arr(a)) => Some(a.map(x => js_string(Some(x))))
      _ => None
    },
  }
}

///|
/// A profile as JSON, as `hubConfig` makes it.
pub fn Profile::to_jv(self : Profile) -> JV {
  self.raw
}
