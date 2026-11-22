// What config.json must be before it is taken (station/src/accounts/check.ts: the Rust station's config.rs
// `parse_config`'s refusals, and the shapes its serde types insist on): `check_config` throws what is wrong, in the
// same words, with what it checks of other parts (ops/agent-env.ts `checkAgentEnv`, mesh/settings.ts `checkNetwork`,
// agents/sandbox.ts `checkSandboxes`) as they say it.

///|
let check_access_kinds : Array[String] = [
  "subscription", "opencode-go", "anthropic-api", "env", "api-provider", "service",
]

///|
let check_modes : Array[String] = ["multi-session", "single-session"]

///|
let connect_kinds : Array[String] = ["slack", "feishu", "comma", "group"]

///|
fn lower_digit(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
}

///|
/// config.rs `id_ok`: a lowercase letter or digit, then those and dashes.
pub fn id_ok(id : String) -> Bool {
  id.length() > 0 &&
  lower_digit(id.unsafe_charcode_at(0).unsafe_to_char()) &&
  id.iter().all(c => lower_digit(c) || c == '-')
}

///|
/// A connect's id: as a profile's, and after a move to another station `@` that station's id.
fn connect_id_ok(id : String) -> Bool {
  let at = index_of(id, "@")
  if at < 0 {
    return id_ok(id)
  }
  let station = slice(id, at + 1)
  id_ok(slice(id, 0, b=at)) &&
  station.length() > 0 &&
  station.iter().all(lower_digit)
}

///|
fn check_fail(message : String) -> Thrown {
  plain_error(message)
}

///|
/// serde's words for a value (`describe`).
fn describe(value : JV?) -> String {
  match value {
    Some(Null) => "null"
    Some(Str(_) as s) => "string \{stringify(s)}"
    Some(Num(n)) =>
      if is_integer(n) {
        "integer `\{num_text(n)}`"
      } else {
        "floating point `\{num_text(n)}`"
      }
    Some(Bool(b)) => "boolean `\{b}`"
    Some(Arr(_)) => "sequence"
    _ => "map"
  }
}

///|
fn variant(
  value : JV?,
  expected : Array[String],
  what : String,
) -> Unit raise Thrown {
  guard value is Some(Str(v)) else {
    raise check_fail("invalid type: \{describe(value)}, expected \{what}")
  }
  if !expected.contains(v) {
    let list = expected.map(e => "`\{e}`")
    let said = if list.length() == 2 {
      "\{list[0]} or \{list[1]}"
    } else {
      "one of \{list.join(", ")}"
    }
    raise check_fail("unknown variant `\{v}`, expected \{said}")
  }
}

///|
fn type_ok(v : JV, t : String) -> Bool {
  match (v, t) {
    (Str(_), "string") => true
    (Bool(_), "boolean") => true
    (Num(_), "number") => true
    _ => false
  }
}

///|
/// `optional`: absent, null, or of that type.
fn optional(v : JV?, t : String, what : String) -> Unit raise Thrown {
  match v {
    None | Some(Null) => ()
    Some(x) =>
      if !is_undef(x) && !type_ok(x, t) {
        raise check_fail("invalid type: \{describe(v)}, expected \{what}")
      }
  }
}

///|
fn present(v : JV?) -> Bool {
  match v {
    None | Some(Null) => false
    Some(x) => !is_undef(x)
  }
}

///|
fn strings_only(v : JV?) -> Bool {
  match v {
    Some(Arr(a)) => a.iter().all(x => x is Str(_))
    _ => false
  }
}

///|
/// ops/agent-env.ts `ENV_NAME`.
pub fn env_name_ok(key : String) -> Bool {
  key.length() > 0 &&
  {
    let c = key.unsafe_charcode_at(0).unsafe_to_char()
    (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'
  } &&
  key
  .iter()
  .all(c => (c >= 'A' && c <= 'Z') ||
    (c >= 'a' && c <= 'z') ||
    (c >= '0' && c <= '9') ||
    c == '_')
}

///|
/// ops/agent-env.ts `checkAgentEnv`.
pub fn check_agent_env(set : JV?) -> Unit raise Thrown {
  if !present(set) {
    return
  }
  guard set is Some(Obj(entries)) else {
    raise check_fail("agentEnv: a map of variables to their values")
  }
  if entries.length() > 64 {
    raise check_fail("agentEnv: at most 64 variables")
  }
  for e in entries {
    if !env_name_ok(e.0) {
      raise check_fail("agentEnv: invalid environment variable name \{e.0}")
    }
    guard e.1 is Str(value) else { raise check_fail("agentEnv.\{e.0}: a string") }
    if value.length() > 4096 ||
      value.contains("\u0000") ||
      value.contains("\n") ||
      value.contains("\r") {
      raise check_fail("agentEnv.\{e.0}: one line of at most 4096 characters")
    }
  }
}

///|
/// mesh/settings.ts `checkNetwork`.
pub fn check_network(raw : JV?) -> Unit raise Thrown {
  if !present(raw) {
    return
  }
  guard raw is Some(Obj(_) as n) else {
    raise check_fail("network: expected an object")
  }
  match n.get("congestion") {
    None | Some(Str("cubic")) | Some(Str("bbr")) => ()
    _ => raise check_fail("network.congestion: expected cubic or bbr")
  }
}

///|
fn sandbox_name_ok(s : String) -> Bool {
  if s.length() < 1 || s.length() > 63 {
    return false
  }
  let first = s.unsafe_charcode_at(0).unsafe_to_char()
  ((first >= 'A' && first <= 'Z') ||
  (first >= 'a' && first <= 'z') ||
  (first >= '0' && first <= '9')) &&
  s
  .iter()
  .all(c => (c >= 'A' && c <= 'Z') ||
    (c >= 'a' && c <= 'z') ||
    (c >= '0' && c <= '9') ||
    c == '.' ||
    c == '_' ||
    c == '-')
}

///|
/// `/^[^\s@]*\{name\}[^\s@]*@[^\s@]+$/`.
fn sandbox_target_ok(s : String) -> Bool {
  if has_space(s) {
    return false
  }
  let parts = split_on(s, "@")
  parts.length() == 2 && parts[0].contains("{name}") && parts[1] != ""
}

///|
fn sandbox_size_ok(s : String) -> Bool {
  if s.length() < 1 || s.length() > 31 {
    return false
  }
  let first = s.unsafe_charcode_at(0).unsafe_to_char()
  first >= 'a' &&
  first <= 'z' &&
  s.iter().all(c => (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')
}

///|
/// agents/sandbox.ts `sandboxRefusal`: why `s` is no sandbox.
fn sandbox_refusal(s : JV) -> String? {
  guard s is (Obj(_) | Arr(_)) else {
    return Some("each is {name, target, size?, identity?}")
  }
  let name = match s.get("name") {
    Some(Str(n)) if sandbox_name_ok(n) => n
    _ => return Some("a name of letters, digits, ., _ and -")
  }
  match s.get("target") {
    Some(Str(t)) if sandbox_target_ok(t) => ()
    _ =>
      return Some(
        "\{name}'s target is its front door, like {name}.WORKSPACE@HOST",
      )
  }
  match s.get("size") {
    None => ()
    Some(Str(z)) if sandbox_size_ok(z) => ()
    _ => return Some("\{name}'s size is the name of one of its operator's sizes")
  }
  match s.get("identity") {
    None => ()
    Some(Str(i)) if i.has_prefix("/") => ()
    _ => return Some("\{name}'s identity is a key's absolute path")
  }
  None
}

///|
/// agents/sandbox.ts `checkSandboxes`.
pub fn check_sandboxes(raw : JV) -> Unit raise Thrown {
  let list = raw.get("sandboxes")
  if !present(list) {
    return
  }
  guard list is Some(Arr(items)) else {
    raise check_fail("sandboxes must be a list")
  }
  let names : Map[String, Unit] = Map::new()
  for s in items {
    match sandbox_refusal(s) {
      Some(why) => raise check_fail("sandboxes: \{why}")
      None => ()
    }
    let name = js_string(s.get("name"))
    if names.contains(lower(name)) {
      raise check_fail("sandboxes: \{name} is named twice")
    }
    names[lower(name)] = ()
  }
}

///|
/// `checkConfig`: throws what parse_config refuses in `raw` (config.json as written).
pub fn check_config(
  raw : JV?,
  _data : String,
  services? : Array[String] = ["colab"],
) -> Unit raise Thrown {
  guard raw is Some(Obj(_) as raw) else {
    raise check_fail("invalid type: \{describe(raw)}, expected struct RawConfig")
  }
  let tools = raw.get("tools")
  if present(tools) {
    guard tools is Some(Obj(_) as t) else {
      raise check_fail("invalid type: \{describe(tools)}, expected struct RawTools")
    }
    match t.get("access") {
      None => ()
      Some(Str("off" | "read" | "full")) => ()
      Some(x) if is_undef(x) => ()
      _ => raise check_fail("tools.access: one of off, read, full")
    }
  }
  check_agent_env(raw.get("agentEnv"))
  check_network(raw.get("network"))
  check_sandboxes(raw)
  let drive = raw.get("drive")
  if present(drive) {
    guard drive is Some(Obj(_) as d) else {
      raise check_fail("invalid type: \{describe(drive)}, expected struct RawDrive")
    }
    let roots = d.get("roots")
    if present(roots) && !strings_only(roots) {
      raise check_fail("drive.roots: a list of paths")
    }
    let joined = d.get("workspaces")
    if present(joined) {
      let ok = match joined {
        Some(Obj(fields)) => fields.iter().all(f => strings_only(Some(f.1)))
        _ => false
      }
      if !ok {
        raise check_fail("drive.workspaces: a list of paths for each workspace")
      }
    }
  }
  let profiles = match raw.get("profiles") {
    None | Some(Null) => JV::Arr([])
    Some(p) => p
  }
  guard profiles is Arr(profile_list) else {
    raise check_fail("invalid type: \{describe(Some(profiles))}, expected a sequence")
  }
  let profile_ids : Array[String] = []
  for p in profile_list {
    guard p is Obj(_) else {
      raise check_fail("invalid type: \{describe(Some(p))}, expected struct RawProfile")
    }
    let id = match p.get("id") {
      Some(Str(i)) => i
      None => raise check_fail("missing field `id`")
      other => raise check_fail("invalid type: \{describe(other)}, expected a string")
    }
    let home = match p.get("home") {
      Some(Str(h)) => h
      None => raise check_fail("missing field `home`")
      other => raise check_fail("invalid type: \{describe(other)}, expected a string")
    }
    if present(p.get("runtime")) {
      variant(p.get("runtime"), runtime_kinds, "a runtime")
    }
    let access_raw = p.get("access")
    if present(access_raw) {
      guard access_raw is Some(Obj(_) as a) else {
        raise check_fail(
          "invalid type: \{describe(access_raw)}, expected struct RawProfileAccess",
        )
      }
      if a.get("kind") is None {
        raise check_fail("missing field `kind`")
      }
      variant(a.get("kind"), check_access_kinds, "an access kind")
      for f in ["key", "provider", "service", "endpoint", "protocol"] {
        optional(a.get(f), "string", "a string")
      }
    }
    for f in ["machine", "backgroundOnMessage", "fast", "enabled", "newAccountProtection"] {
      optional(p.get(f), "boolean", "a boolean")
    }
    optional(p.get("name"), "string", "a string")
    optional(p.get("model"), "string", "a string")
    if present(p.get("maxConcurrentSessions")) {
      match p.get("maxConcurrentSessions") {
        Some(Num(n)) if is_integer(n) && n >= 0.0 => ()
        _ =>
          raise check_fail(
            "profile \{id}: maxConcurrentSessions must be a non-negative integer",
          )
      }
    }
    if present(p.get("models")) && !strings_only(p.get("models")) {
      raise check_fail("invalid type: expected a sequence of strings")
    }
    let env = p.get("env")
    if present(env) {
      let ok = match env {
        Some(Obj(fields)) => fields.iter().all(f => f.1 is Str(_))
        _ => false
      }
      if !ok {
        raise check_fail("invalid type: expected a map of strings")
      }
    }
    if present(p.get("withheld")) && !strings_only(p.get("withheld")) {
      raise check_fail("invalid type: expected a sequence of strings")
    }
    if !id_ok(id) {
      raise check_fail(
        "profile id \{stringify(js(id))}: use lowercase letters, digits and dashes",
      )
    }
    if home == "" {
      raise check_fail("profile \{id}: home is required")
    }
    let access = match access_raw {
      Some(Obj(_) as a) => Some(a)
      _ => None
    }
    let kind = match jget(access, "kind") {
      None | Some(Null) => "env"
      Some(k) => js_string(Some(k))
    }
    let runtimes = runtimes_for(access, p.get("runtime"))
    let provider = nonempty_str(jget(access, "provider"))
    let service = nonempty_str(jget(access, "service"))
    let endpoint = match jget(access, "endpoint") {
      Some(Str(e)) => clean_endpoint(e)
      _ => None
    }
    let protocol = nonempty_str(jget(access, "protocol"))
    if kind == "service" {
      if present(p.get("runtime")) {
        raise check_fail("profile \{id}: service profile must not set runtime")
      }
      guard service is Some(svc) && id_ok(svc) else {
        raise check_fail("profile \{id}: service access needs a valid service id")
      }
      if !services.contains(svc) {
        raise check_fail("profile \{id}: unknown service \{svc}")
      }
    } else if kind == "api-provider" {
      let s = match provider {
        None => None
        Some(pid) => find_source(pid)
      }
      guard s is Some(s) else {
        raise check_fail("profile \{id}: api-provider needs a known provider")
      }
      if endpoints(s, endpoint, protocol) is None {
        raise check_fail("profile \{id}: \{s.name} needs an endpoint address")
      }
    } else if runtimes.length() == 0 {
      raise check_fail(
        "profile \{id}: \{kind} needs a runtime (claude, codex or dsh)",
      )
    }
    if !runtimes.iter().all(r => access_kinds(r).contains(kind)) {
      raise check_fail(
        "profile \{id}: \{runtimes.join("/")} cannot use access \{kind}",
      )
    }
    let key = trim_js(
      match jget(access, "key") {
        None | Some(Null) => ""
        v => js_string(v)
      },
    )
    optional(jget(access, "login"), "boolean", "a boolean")
    let signed_in = kind == "api-provider" &&
      provider == Some("kimi-code") &&
      jget(access, "login") == Some(Bool(true))
    if needs_key(kind, provider) && key == "" && !signed_in {
      raise check_fail("profile \{id}: access \{kind} needs a key")
    }
    profile_ids.push(id)
  }
  unique_ids("profile", profile_ids)
  let connects = match raw.get("connects") {
    None | Some(Null) => JV::Arr([])
    Some(c) => c
  }
  guard connects is Arr(connect_list) else {
    raise check_fail("invalid type: \{describe(Some(connects))}, expected a sequence")
  }
  let connect_ids : Array[String] = []
  for c in connect_list {
    guard c is Obj(_) else {
      raise check_fail("invalid type: \{describe(Some(c))}, expected struct RawConnect")
    }
    let id = match c.get("id") {
      Some(Str(i)) => i
      None => raise check_fail("missing field `id`")
      other => raise check_fail("invalid type: \{describe(other)}, expected a string")
    }
    let bind = match c.get("bind") {
      Some(Obj(_) as b) => b
      None => raise check_fail("missing field `bind`")
      other => raise check_fail("invalid type: \{describe(other)}, expected struct RawBind")
    }
    if bind.get("runtime") is None {
      raise check_fail("missing field `runtime`")
    }
    variant(bind.get("runtime"), runtime_kinds, "a runtime")
    if present(c.get("mode")) {
      variant(c.get("mode"), check_modes, "a connect mode")
    }
    for f in ["model", "effort", "profile"] {
      optional(bind.get(f), "string", "a string")
    }
    let bp = bind.get("profiles")
    if present(bp) {
      guard bp is Some(Arr(list)) else {
        raise check_fail("invalid type: \{describe(bp)}, expected a sequence")
      }
      for x in list {
        if !(x is Str(_)) {
          raise check_fail("invalid type: \{describe(Some(x))}, expected a string")
        }
      }
    }
    if !connect_id_ok(id) {
      raise check_fail(
        "connect id \{stringify(js(id))}: use lowercase letters, digits and dashes",
      )
    }
    let kind = match c.get("kind") {
      None | Some(Null) => js("slack")
      Some(k) => k
    }
    if !(match kind {
        Str(k) => connect_kinds.contains(k)
        _ => false
      }) {
      raise check_fail("connect \{id}: unknown kind \{js_string(Some(kind))}")
    }
    let runtime = js_string(bind.get("runtime"))
    match bind.get("effort") {
      Some(Str(effort)) if effort != "" => {
        let allowed = if runtime == "agy" { agy_levels } else { fallback_efforts(runtime) }
        if runtime != "codex" && !allowed.contains(effort) {
          let hint = if allowed.length() > 0 { "; use \{allowed.join(", ")}" } else { "" }
          raise check_fail(
            "connect \{id}: \{runtime} has no effort \{effort}\{hint}",
          )
        }
      }
      _ => ()
    }
    connect_ids.push(id)
  }
  unique_ids("connect", connect_ids)
  let decisions = raw.get("automaticDecisions")
  if present(decisions) {
    check_automatic_decisions(decisions)
  }
}

///|
/// `checkAutomaticDecisions`: `{completion?: {enabled?: bool, model?: string|null}}`, nothing else.
pub fn check_automatic_decisions(value : JV?) -> Unit raise Thrown {
  guard value is Some(Obj(fields) as v) else {
    raise check_fail(
      "invalid type: \{describe(value)}, expected struct AutomaticDecisions",
    )
  }
  for f in fields {
    if f.0 != "completion" {
      raise check_fail("unknown field `\{f.0}`, expected `completion`")
    }
  }
  let rule = v.get("completion")
  guard rule is Some(r) else { return }
  if is_undef(r) {
    return
  }
  guard r is Obj(rfields) else {
    raise check_fail("invalid type: \{describe(rule)}, expected struct DecisionRule")
  }
  for f in rfields {
    if f.0 != "enabled" && f.0 != "model" {
      raise check_fail("unknown field `\{f.0}`, expected `enabled` or `model`")
    }
  }
  if r.get("enabled") is Some(_) {
    optional(r.get("enabled"), "boolean", "a boolean")
  }
  if r.get("enabled") == Some(Null) {
    raise check_fail("invalid type: null, expected a boolean")
  }
  optional(r.get("model"), "string", "a string")
}

///|
fn unique_ids(kind : String, ids : Array[String]) -> Unit raise Thrown {
  let seen : Map[String, Unit] = Map::new()
  for id in ids {
    if seen.contains(id) {
      raise check_fail("duplicate \{kind} id \{id}")
    }
    seen[id] = ()
  }
}
