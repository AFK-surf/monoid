// What the hub reads of config.json (station/src/sessions/config.ts, the Rust station's config.rs as parse_config
// fills it in): profiles, connects, and the numbers that govern turns, warm processes and archiving. A profile stays
// config.json's object, its home made absolute and what parse_config derives added. What a profile runs and how a model
// is spelled are the agents' parts' (`dep.profileRuntimes`, `dep.modelKey`, `dep.agyBaseModel`,
// `dep.splitDevinFusion`, `dep.devinFusionBase`), which the station gives.

///|
pub let runtime_kinds : Array[String] = @agent_runtimes.runtime_kinds

///|
/// agents/runtime.ts `runtimeKind` and `runtimeLabel`.
pub using @agent_runtimes {runtime_kind, runtime_label as runtime_title}

///|
fn is_absolute(p : String) -> Bool {
  starts(p, "/")
}

///|
fn under(data_dir : String, path : String) -> String {
  if is_absolute(path) {
    path
  } else {
    join_path([data_dir, path])
  }
}

///|
using @jsjson {jval_nonempty as non_empty, js_trunc}

///|
/// `String(v)` for what a config's field may be.
pub fn js_string_of(v : J?) -> String {
  match v {
    None => "undefined"
    Some(Null) => "null"
    Some(Bool(b)) => if b { "true" } else { "false" }
    Some(Num(d)) => num_text(d)
    Some(Str(u)) => @jsjson.sanitize_str(u)
    Some(Arr(xs)) => xs.map(x => if x is Null { "" } else { js_string_of(Some(x)) }).join(",")
    Some(Obj(_)) => "[object Object]"
  }
}

///|
/// A profile named as it was before (「b@x.com（本机）」, "Local Codex") without the "this machine" it was said with.
fn machine_name(name : String) -> String {
  let mut n = name
  if ends(n, "（本机）") {
    n = slice(n, 0, b=n.length() - 4)
  } else if ends(n, " (local)") {
    n = slice(n, 0, b=n.length() - 8)
  }
  if starts(n, "本机 ") {
    n = slice(n, 3)
  } else if starts(n, "Local ") {
    n = slice(n, 6)
  }
  n
}

///|
/// `o[k] = v`, or the key's value left out of what JSON says where `v` is undefined.
fn put(o : J, k : String, v : J?) -> J {
  match v {
    Some(x) => set_field(o, k, x)
    None =>
      // (kept in its place as undefined: JSON leaves it out)
      without(o, [k])
  }
}

///|
fn num_or(v : J?, d : Double) -> Double {
  match v {
    Some(Num(x)) => x
    _ => d
  }
}

///|
/// Default concurrent turn cap scaled by host RAM: floor(total_bytes / 1.5 GiB), clamped to [4, 32] (0 if unknown).
pub fn default_max_concurrent_turns(total_bytes : Double) -> Double {
  if total_bytes.is_nan() || total_bytes.is_inf() || !(total_bytes > 0.0) {
    return 0.0
  }
  let gib = 1073741824.0
  let n = (total_bytes / (1.5 * gib)).floor()
  if n < 4.0 {
    4.0
  } else if n > 32.0 {
    32.0
  } else {
    n
  }
}

///|
/// config.json (parsed) as the hub reads it: parse_config's defaults and derivations. `found`: the models a profile's
/// last check found (by its id).
pub async fn hub_config(_w : World, raw : J, data_dir : String, found : (String) -> Array[String]?, total_bytes? : Double = 0.0) -> J {
  let profiles = []
  for p in arr_of(at(Some(raw), "profiles")).unwrap_or([]) {
    let seen : Array[String] = []
    let models : Array[String] = []
    for m in arr_of(at(Some(p), "models")).unwrap_or([]) {
      let t = trim(js_string_of(Some(m)))
      if t != "" && !seen.contains(t) {
        seen.push(t)
        models.push(t)
      }
    }
    let base = spread(p, jo([("home", js(under(data_dir, js_string_of(match at(Some(p), "home") { Some(Null) | None => Some(js("")); v => v }))))]))
    let runtimes = @agent_runtimes.profile_runtimes(base)
    let runs = models.copy()
    if runtimes.length() > 0 {
      let has : Array[String] = []
      for m in models {
        has.push(@readops.model_key(m))
      }
      for m in found(js_string_of(at(Some(p), "id"))).unwrap_or([]) {
        if m == "" {
          continue
        }
        let k = @readops.model_key(m)
        if has.contains(k) {
          continue
        }
        has.push(k)
        runs.push(m)
      }
    }
    let named = if at(Some(p), "machine") is Some(Bool(true)) {
      match str_of(at(Some(p), "name")) {
        Some(n) => Some(machine_name(n))
        None => None
      }
    } else {
      str_of(at(Some(p), "name"))
    }
    let name = match named {
      Some(n) if trim(n) != "" => js(trim(n))
      _ => at(Some(p), "id").unwrap_or(Null)
    }
    let mut out = base
    out = put(out, "id", at(Some(p), "id"))
    out = put(out, "name", Some(name))
    out = put(out, "runtime", Some(js(if runtimes.length() > 0 { runtimes[0] } else { "claude" })))
    out = put(out, "runtimes", Some(jsa(runtimes)))
    out = put(out, "models", Some(jsa(runs)))
    out = put(out, "named", Some(jsa(models)))
    out = put(out, "model", match non_empty(at(Some(p), "model")) { Some(m) => Some(js(m)); None => None })
    out = put(out, "backgroundOnMessage", Some(jb(!(at(Some(p), "backgroundOnMessage") is Some(Bool(false))))))
    out = put(out, "enabled", Some(jb(!(at(Some(p), "enabled") is Some(Bool(false))))))
    match arr_of(at(Some(p), "withheld")) {
      Some(ws) => out = put(out, "withheld", Some(ja(ws.filter(x => x is Str(u) && u.length() > 0))))
      None => ()
    }
    profiles.push(out)
  }
  let connects = []
  for c in arr_of(at(Some(raw), "connects")).unwrap_or([]) {
    let mode = if str_of(at(Some(c), "mode")) == Some("single-session") { "single-session" } else { "multi-session" }
    let bind = match at(Some(c), "bind") {
      Some(Null) | None => J::Obj([])
      Some(b) => b
    }
    let bind_profiles : Array[String] = []
    match arr_of(at(Some(bind), "profiles")) {
      Some(xs) =>
        for x in xs {
          match str_of(Some(x)) {
            Some(s) if trim(s) != "" => {
              let t = trim(s)
              if !bind_profiles.contains(t) {
                bind_profiles.push(t)
              }
            }
            _ => ()
          }
        }
      None => ()
    }
    let single = match non_empty(at(Some(bind), "profile")) {
      Some(s) => Some(s)
      None => if bind_profiles.length() == 1 { Some(bind_profiles[0]) } else { None }
    }
    let kind = match str_of(at(Some(c), "kind")) {
      Some("feishu") => "feishu"
      Some("comma") => "comma"
      Some("group") => "group"
      _ => "slack"
    }
    let slack = spread(
      match at(Some(c), "slack") {
        Some(Null) | None => J::Obj([])
        Some(s) => spread(Obj([]), s)
      },
      Obj([]),
    )
    let slack = put(slack, "botName", match non_empty(at(at(Some(c), "slack"), "botName")) { Some(b) => Some(js(b)); None => None })
    let bind_fields = [("runtime", js(runtime_kind(at(Some(bind), "runtime")).unwrap_or("claude")))]
    if single is Some(s) {
      bind_fields.push(("profile", js(s)))
    }
    if bind_profiles.length() > 0 {
      bind_fields.push(("profiles", jsa(bind_profiles)))
    } else if single is Some(s) {
      bind_fields.push(("profiles", jsa([s])))
    }
    if non_empty(at(Some(bind), "model")) is Some(m) {
      bind_fields.push(("model", js(m)))
    }
    if non_empty(at(Some(bind), "effort")) is Some(e) {
      bind_fields.push(("effort", js(e)))
    }
    let fields = [
      ("id", at(Some(c), "id")),
      ("kind", Some(js(kind))),
      ("enabled", Some(jb(!(at(Some(c), "enabled") is Some(Bool(false)))))),
      ("mode", Some(js(mode))),
      ("requireMention", Some(jb(mode == "multi-session" || !(at(Some(c), "requireMention") is Some(Bool(false)))))),
      ("slack", Some(slack)),
      ("bind", Some(jo(bind_fields))),
    ]
    if non_empty(at(Some(c), "workspace")) is Some(ws) {
      fields.push(("workspace", Some(js(ws))))
    }
    connects.push(jo(fields.filter_map(f => match f.1 { Some(v) => Some((f.0, v)); None => None })))
  }
  let completion = match at(at(Some(raw), "automaticDecisions"), "completion") {
    Some(Null) | None => J::Obj([])
    Some(x) => x
  }
  let agent_home = under(data_dir, str_of(at(Some(raw), "agentHome")).unwrap_or("agent"))
  let days = (k : String, d : Double) => js_trunc(@cmp.maximum(0.0, num_or(at(Some(raw), k), d)) * 86400000.0)
  let afresh_above = match at(Some(raw), "afreshAbove") {
    Some(Num(x)) if !x.is_nan() && !x.is_inf() && x >= 0.0 => x
    _ => 1.0
  }
  let max_concurrent_turns = match at(Some(raw), "maxConcurrentTurns") {
    Some(Num(x)) if !x.is_nan() && !x.is_inf() => if x > 0.0 { js_trunc(x) } else { 0.0 }
    _ => default_max_concurrent_turns(total_bytes)
  }
  jo([
    ("dataDir", js(data_dir)),
    ("agentHome", js(agent_home)),
    ("connects", ja(connects)),
    ("profiles", ja(profiles)),
    ("maxNudges", jn(num_or(at(Some(raw), "maxNudges"), 2.0))),
    ("askToName", jb(!(at(Some(raw), "askToName") is Some(Bool(false))))),
    (
      "automaticDecisions",
      jo([
        (
          "completion",
          jo([
            ("enabled", jb(at(Some(completion), "enabled") is Some(Bool(true)))),
            ("model", jopt(str_of(at(Some(completion), "model")))),
          ]),
        ),
      ]),
    ),
    ("warmMs", jn(js_trunc(num_or(at(Some(raw), "warmMinutes"), 30.0) * 60000.0))),
    ("maxWarmClaude", jn(num_or(at(Some(raw), "maxWarmClaude"), 4.0))),
    ("maxConcurrentTurns", jn(max_concurrent_turns)),
    ("autoArchiveMs", jn(days("autoArchiveDays", 1.0))),
    ("slackArchiveMs", jn(days("slackArchiveDays", 3.0))),
    ("autoArchiveReviewed", jb(at(Some(raw), "autoArchiveReviewed") is Some(Bool(true)))),
    ("archivedWorkspaceMs", jn(days("archivedWorkspaceDays", 7.0))),
    ("afreshWhenCold", jb(at(Some(raw), "afreshWhenCold") is Some(Bool(true)))),
    ("afreshAbove", jn(afresh_above)),
  ])
}

///|
fn strings(v : J?) -> Array[String] {
  arr_of(v).unwrap_or([]).filter_map(x => str_of(Some(x)))
}

///|
/// shapes model.rs `same`: two spellings are one model.
pub async fn same_model(_w : World, a : String, b : String) -> Bool {
  @session_hub.same_model(a, b)
}

///|
/// Its own spelling of a model it runs, however the model is spelled.
pub async fn spelling(_w : World, profile : J, model : String) -> String? {
  @session_hub.spelling(profile.to_json(), model)
}

///|
/// Whether it runs a model, in any spelling.
pub async fn runs(w : World, profile : J, model : String) -> Bool {
  spelling(w, profile, model) is Some(_)
}

///|
/// Whether sessions of workspace `ws` (None: the home one's) may run on a profile.
pub fn allowed_in(profile : J, ws : String?, home : String?) -> Bool {
  @session_hub.allowed_in(profile.to_json(), ws, home)
}

///|
/// The profiles a connect's sessions can run on: every profile of its runtime allowed in its workspace.
pub fn profiles_for(config : J, connect : J, home : String?) -> Array[J] {
  let runtime = str_of(at(at(Some(connect), "bind"), "runtime")).unwrap_or("")
  let ws = str_of(at(Some(connect), "workspace"))
  arr_of(at(Some(config), "profiles"))
  .unwrap_or([])
  .filter(p => !(at(Some(p), "enabled") is Some(Bool(false))) &&
    strings(at(Some(p), "runtimes")).contains(runtime) &&
    allowed_in(p, ws, home))
}

///|
pub fn runtime_named(name : String) -> String? {
  runtime_kind(Some(js(name)))
}
