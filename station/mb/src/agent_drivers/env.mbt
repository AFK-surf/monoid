// What a runtime's process is started with that is not one driver's: the station's environment for what it starts
// (ops/agent-env.ts `startEnv`, `keepLocal`), a profile's variables with its route (profiles.ts `expandRoute`), the
// address of the other stations' web services (tools/http.ts `peerHttpBase`), a runner's id (process.ts `runnerId`,
// sandbox-name.ts `keyPart`) and what the drivers read of a profile (profiles.ts). A profile's own variables for a
// runtime and Codex's overrides of it are its providers' (profiles.ts `profileEnv`, `codexOverrides`): the drivers are
// given them (`ProfileSays`).

///|
/// Variables in the order they were set (a JavaScript object of strings).
pub struct Env {
  pairs : Array[(String, String)]
}

///|
pub fn Env::new(pairs : Array[(String, String)]) -> Env {
  { pairs: pairs.copy() }
}

///|
pub fn Env::get(self : Env, k : String) -> String? {
  for p in self.pairs {
    if p.0 == k {
      return Some(p.1)
    }
  }
  None
}

///|
pub fn Env::has(self : Env, k : String) -> Bool {
  self.get(k) is Some(_)
}

///|
pub fn Env::set(self : Env, k : String, v : String) -> Unit {
  for i, p in self.pairs {
    if p.0 == k {
      self.pairs[i] = (k, v)
      return
    }
  }
  self.pairs.push((k, v))
}

///|
/// `env.k ??= v`.
pub fn Env::set_unset(self : Env, k : String, v : String) -> Unit {
  if !self.has(k) {
    self.set(k, v)
  }
}

///|
pub fn Env::delete(self : Env, k : String) -> Unit {
  match self.pairs.search_by(p => p.0 == k) {
    Some(i) => self.pairs.remove(i) |> ignore
    None => ()
  }
}

///|
/// `{ ...this, ...more }`.
pub fn Env::merge(self : Env, more : Array[(String, String)]) -> Unit {
  for p in more {
    self.set(p.0, p.1)
  }
}

///|
pub fn Env::to_json(self : Env) -> JValue {
  map_json(self.pairs)
}

///|
let proxies : Array[String] = ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY"]

///|
let local_hosts : Array[String] = ["localhost", "127.0.0.1", "::1"]

///|
/// A variable whatever its case (`either`): its value where it is set and not empty.
pub fn either(env : Env, name : String) -> String? {
  match env.get(name) {
    Some(v) if v != "" => Some(v)
    _ =>
      match env.get(@jscase.lower(name)) {
        Some(v) if v != "" => Some(v)
        _ => None
      }
  }
}

///|
/// `env` going through a proxy: this machine left out of it in both cases of NO_PROXY (`keepLocal`).
pub fn keep_local(env : Env) -> Env {
  if !proxies.iter().any(p => either(env, p) is Some(_)) {
    return env
  }
  let named = either(env, "NO_PROXY")
    .unwrap_or("")
    .split(",")
    .map(h => @jscase.trim(h.to_string()))
    .filter(h => h != "")
    .collect()
  if named.contains("*") {
    return env
  }
  let kept = named + local_hosts.filter(h => !named.contains(h))
  let out = Env::new(env.pairs)
  let joined = kept.join(",")
  out.set("NO_PROXY", joined)
  out.set("no_proxy", joined)
  out
}

///|
/// The station's environment for what it starts (`startEnv`): `raw` (its own with its owners' variables over it) less
/// `scrubbed`, this machine kept out of a proxy.
pub fn start_env(raw : Env, scrubbed : Array[String]) -> Env {
  keep_local(Env::new(raw.pairs.filter(p => !scrubbed.contains(p.0))))
}

///|
/// `{route}` in a profile's values, the session's (`expandRoute`).
pub fn expand_route(env : Array[(String, String)], route : String) -> Array[(String, String)] {
  env.map(p => (p.0, p.1.replace_all(old="{route}", new=route)))
}

///|
/// Web services of the workspace's other stations beside the station's tools (`peerHttpBase`).
pub fn peer_http_base(mcp_url : String) -> String {
  if mcp_url.has_suffix("/mcp") {
    mcp_url.substring(end=mcp_url.length() - 4) + "/peer"
  } else {
    mcp_url
  }
}

///|
/// A station's key as a runner's id has it after its kind (`keyPart`).
pub fn key_part(key : String) -> String {
  let clean = StringBuilder()
  let u = @jsjson.units(key)
  for c in u {
    let ok = ascii_word(c) || c == 0x2d
    clean.write_char(if ok { c.unsafe_to_char() } else { '_' })
  }
  let cleaned = clean.to_string()
  let cut = if cleaned.length() > 24 {
    cleaned.substring(end=24)
  } else {
    cleaned
  }
  if cut == key {
    cut
  } else {
    let hash = @cloud_lock.sha256_hex(key)
    "\{cut}-\{hash.substring(end=10)}"
  }
}

///|
/// A runner id from a session key or a profile id (`runnerId`).
pub fn runner_id(kind : String, key : String) -> String {
  "\{kind}-\{key_part(key)}"
}

///|
/// What the drivers are told of a profile beyond its fields: the variables its runtime is started with (`{route}` still
/// in them: profiles.ts `profileEnv`), and Codex's overrides of its config (`codexOverrides`, in key order).
pub(all) struct ProfileSays {
  env : (JValue, String) -> Array[(String, String)]
  codex_overrides : (JValue) -> Array[(String, String)]
}

///|
/// A non-empty string field.
pub fn filled(v : JValue?, name : String) -> String? {
  match str_at(v, name) {
    Some(t) if t != "" => Some(t)
    _ => None
  }
}

///|
pub fn access_of(p : JValue) -> JValue? {
  match p.get("access") {
    Some(Obj(_)) as a => a
    _ => None
  }
}

///|
pub using @agent_runtimes {
  access_kind,
  profile_model,
  is_machine,
  profile_fast,
  takes_fast,
  kimi_signed_in,
}

///|
pub fn profile_id(p : JValue) -> String {
  str_at(Some(p), "id").unwrap_or("")
}

///|
pub fn profile_home(p : JValue) -> String {
  str_at(Some(p), "home").unwrap_or("")
}
