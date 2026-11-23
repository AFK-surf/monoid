// profiles.ts: how a profile's account reaches its models (`codex_overrides`), and the environment a profile's runtime
// is started with (`profile_env`: what the access kind needs there plus the profile's own variables, which win). A
// profile is config.json's object, its home made absolute.

///|
/// runtime.ts `RUNTIME_KINDS`.
pub let runtime_kinds : Array[String] = ["claude", "codex", "dsh", "grok", "cursor", "devin", "hermes", "agy", "pi"]

///|
/// runtime.ts `runtimeKind`.
pub fn runtime_kind(v : J?) -> String? {
  match str_of(v) {
    Some(k) if runtime_kinds.contains(k) => Some(k)
    _ => None
  }
}

///|
/// runtime.ts `runtimeLabel`.
pub fn runtime_label(r : String) -> String {
  match r {
    "claude" => "Claude Code"
    "codex" => "Codex"
    "dsh" => "DeepSeek Harness"
    "grok" => "Grok Build"
    "cursor" => "Cursor"
    "hermes" => "Hermes Agent"
    "agy" => "Antigravity CLI"
    "pi" => "Pi"
    _ => "Devin"
  }
}

///|
fn access(p : J) -> J? {
  let a = get(Some(p), "access")
  if is_object(a) {
    a
  } else {
    None
  }
}

///|
/// accounts/kimi.ts `KIMI_TOKEN_FILE`.
pub let kimi_token_file : String = "kimi-code.token"

///|
/// `KIMI_CODE`: the provider of Kimi Code's membership.
pub let kimi_code : String = "kimi-code"

///|
/// `accessKind`: "subscription", "opencode-go", "anthropic-api", "env", "api-provider" or "service" (another value as it is).
pub fn access_kind(p : J) -> String {
  match get(access(p), "kind") {
    None | Some(Null) => "env"
    Some(Str(s)) => t(s)
    Some(other) => @jsjson.jv_js_string(Some(other))
  }
}

///|
/// `profileService`: the service id of a `service` profile (None for non-service profiles).
pub fn profile_service(p : J) -> String? {
  if access_kind(p) != "service" {
    return None
  }
  nonempty(get(access(p), "service"))
}

///|
fn provider_of(p : J) -> J? {
  get(access(p), "provider")
}

///|
pub fn billed_per_use(p : J) -> Bool {
  let kind = access_kind(p)
  kind == "anthropic-api" || kind == "env" || (kind == "api-provider" && !is_s(provider_of(p), kimi_code))
}

///|
pub fn kimi_signed_in(p : J) -> Bool {
  access_kind(p) == "api-provider" && is_s(provider_of(p), kimi_code) && is_true(get(access(p), "login"))
}

///|
fn home_of(p : J) -> String {
  str_of(get(Some(p), "home")).unwrap_or("")
}

///|
pub fn key_file(p : J) -> String? {
  if kimi_signed_in(p) {
    Some(join([home_of(p), kimi_token_file]))
  } else {
    None
  }
}

///|
/// `vertexKeyFile`: where a Google Vertex AI profile's service account JSON is written for `agy`.
pub fn vertex_key_file(home : String) -> String {
  join([home, "agy", "vertex-credentials.json"])
}

///|
/// `vertexAccount`: parses a Google Cloud service account JSON key; returns its project id when valid.
pub fn vertex_account(key : String) -> String? {
  guard parse(key) is Some(parsed) && is_object(Some(parsed)) else { return None }
  if !is_s(get(Some(parsed), "type"), "service_account") {
    return None
  }
  let filled = (field : String) => match str_of(get(Some(parsed), field)) {
    Some(s) if trim(s) != "" => Some(trim(s))
    _ => None
  }
  guard filled("project_id") is Some(project) else { return None }
  guard filled("client_email") is Some(_) else { return None }
  guard filled("private_key") is Some(_) else { return None }
  Some(project)
}

///|
pub fn profile_model(p : J) -> String? {
  nonempty(get(Some(p), "model"))
}

///|
pub fn is_machine(p : J) -> Bool {
  is_true(get(Some(p), "machine"))
}

///|
pub fn profile_fast(p : J) -> Bool {
  is_true(get(Some(p), "fast"))
}

///|
pub let fast_runtimes : Array[String] = ["codex", "claude"]

///|
pub fn takes_fast(p : J) -> Bool {
  let kind = access_kind(p)
  let runtime = get(Some(p), "runtime")
  if is_s(runtime, "codex") {
    return kind == "subscription"
  }
  if !is_s(runtime, "claude") {
    return false
  }
  kind == "anthropic-api" || kind == "subscription" || (kind == "api-provider" && is_s(provider_of(p), "openrouter"))
}

///|
pub fn fast_needs_credits(p : J) -> Bool {
  is_s(get(Some(p), "runtime"), "claude") && access_kind(p) == "subscription"
}

///|
/// `Via`: which provider an API-provider profile is on, and where.
pub(all) struct Via {
  provider : String?
  endpoint : String?
  protocol : String?
}

///|
pub fn profile_via(p : J) -> Via {
  let a = access(p)
  let endpoint = match get(a, "endpoint") {
    None => None
    Some(Str(s)) => clean_endpoint(t(s))
    Some(_) => None
  }
  { provider: nonempty(get(a, "provider")), endpoint, protocol: nonempty(get(a, "protocol")) }
}

///|
/// `apiSource`: the source of an API-provider profile and where it speaks, when it names a known provider.
pub fn api_source(via : Via) -> (Source, Endpoints)? {
  guard via.provider is Some(id) else { return None }
  guard find(id) is Some(source) else { return None }
  match endpoints(source, via.endpoint, via.protocol) {
    Some(at) => Some((source, at))
    None => None
  }
}

///|
let no_key : String = "none"

///|
pub let opencode : String = "https://opencode.ai/zen/go"

///|
pub let opencode_small : String = "claude-haiku-5-5"

///|
let codex_key : String = "STILLFAIL_API_KEY"

///|
pub let dsh_key : String = "STILLFAIL_DSH_KEY"

///|
pub let pi_key : String = "STILLFAIL_PI_KEY"

///|
/// `accessEnv`: the environment an access kind needs. `{route}` is expanded per session later.
pub fn access_env(runtime : String, kind : String, key : String, model : String?, via : Via) -> Fields {
  let env = Fields::new()
  if kind == "opencode-go" && runtime == "claude" {
    let small = model.unwrap_or(opencode_small)
    env.set_str("ANTHROPIC_BASE_URL", opencode)
    env.set_str("ANTHROPIC_API_KEY", key)
    env.set_str("ANTHROPIC_CUSTOM_HEADERS", "x-opencode-session: {route}")
    env.set_str("ANTHROPIC_DEFAULT_HAIKU_MODEL", small)
    env.set_str("ANTHROPIC_SMALL_FAST_MODEL", small)
    env.set_str("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1")
    return env
  }
  if kind == "opencode-go" && runtime == "codex" {
    env.set_str("OPENCODE_GO_KEY", key)
    env.set_str("OPENCODE_SESSION", "stillfail-{route}")
    return env
  }
  if (kind == "opencode-go" || kind == "anthropic-api") && runtime == "dsh" {
    env.set_str(dsh_key, key)
    return env
  }
  if (kind == "opencode-go" || kind == "anthropic-api") && runtime == "pi" {
    env.set_str(pi_key, key)
    return env
  }
  if runtime == "grok" {
    if kind == "api-provider" && via.provider is Some("xai") {
      env.set_str("XAI_API_KEY", key)
    }
    return env
  }
  if runtime == "agy" {
    if kind == "api-provider" && via.provider is Some("google") {
      env.set_str("GEMINI_API_KEY", key)
    }
    return env
  }
  if kind == "anthropic-api" {
    env.set_str("ANTHROPIC_API_KEY", key)
    return env
  }
  if kind == "api-provider" {
    return api_env(runtime, key, model, via)
  }
  env
}

///|
fn api_env(runtime : String, key : String, model : String?, via : Via) -> Fields {
  let env = Fields::new()
  guard api_source(via) is Some((source, at)) else { return env }
  let key_or_none = if key == "" { no_key } else { key }
  if runtime == "claude" {
    guard at.anthropic is Some(anthropic) else { return env }
    env.set_str("ANTHROPIC_BASE_URL", anthropic)
    if source.auth == "apiKey" {
      env.set_str("ANTHROPIC_API_KEY", key_or_none)
    } else if source.auth == "bearer" {
      env.set_str("ANTHROPIC_AUTH_TOKEN", key_or_none)
      env.set_str("ANTHROPIC_API_KEY", "")
    } else {
      env.set_str("ANTHROPIC_AUTH_TOKEN", key_or_none)
      env.set_str("ANTHROPIC_API_KEY", key_or_none)
    }
    if source.session_header {
      env.set_str("ANTHROPIC_CUSTOM_HEADERS", "x-opencode-session: {route}")
    }
    if model is Some(m) {
      env.set_str("ANTHROPIC_DEFAULT_HAIKU_MODEL", m)
      env.set_str("ANTHROPIC_SMALL_FAST_MODEL", m)
    }
    env.set_str("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1")
    return env
  }
  if runtime == "dsh" {
    match dsh_route_of("api-provider", via) {
      None => ()
      Some(Deepseek) => env.set_str("DEEPSEEK_API_KEY", key_or_none)
      Some(_) => env.set_str(dsh_key, key_or_none)
    }
    return env
  }
  if runtime == "pi" {
    if pi_route_of("api-provider", via) is Some(_) {
      env.set_str(pi_key, key_or_none)
    }
    return env
  }
  guard at.responses is Some(_) else { return env }
  env.set_str(codex_key, key_or_none)
  if source.session_header {
    env.set_str("OPENCODE_SESSION", "stillfail-{route}")
  }
  env
}

///|
/// `codexOverrides`: Codex's model provider as `-c` overrides (TOML values), in key order.
pub fn codex_overrides(kind : String, model : String?, via : Via) -> Array[(String, String)] {
  let out = Fields::new()
  out.set_str("features.apps", "false")
  out.set_str("features.recommended_plugins", "false")
  let sorted = () => sort_js(out.entries(), e => e.0).map(e => (e.0, str_of(Some(e.1)).unwrap_or("")))
  if kind == "api-provider" {
    guard api_source(via) is Some((source, at)) else { return sorted() }
    guard at.responses is Some(responses) else { return sorted() }
    out.set_str("model_provider", "\"api\"")
    if model is Some(m) {
      out.set_str("model", quote(m))
    }
    out.set_str("model_providers.api.name", quote(source.name))
    out.set_str("model_providers.api.base_url", quote(responses))
    out.set_str("model_providers.api.env_key", "\"\{codex_key}\"")
    out.set_str("model_providers.api.wire_api", "\"responses\"")
    if source.session_header {
      out.set_str("model_providers.api.env_http_headers", "{\"x-opencode-session\"=\"OPENCODE_SESSION\"}")
    }
    return sorted()
  }
  if kind != "opencode-go" {
    return sorted()
  }
  out.set_str("model_provider", "\"opencode-go\"")
  if model is Some(m) {
    out.set_str("model", quote(m))
  }
  out.set_str("model_providers.opencode-go.name", "\"OpenCode Go\"")
  out.set_str("model_providers.opencode-go.base_url", "\"\{opencode}/v1\"")
  out.set_str("model_providers.opencode-go.env_key", "\"OPENCODE_GO_KEY\"")
  out.set_str("model_providers.opencode-go.wire_api", "\"responses\"")
  out.set_str("model_providers.opencode-go.env_http_headers", "{\"x-opencode-session\"=\"OPENCODE_SESSION\"}")
  sorted()
}

///|
/// `PiRoute`: a route on pi-ai, the protocol it speaks ("openai-completions", "anthropic-messages",
/// "openai-responses").
pub(all) struct PiRoute {
  name : String
  api : String
  base_url : String
  headers : Fields?
}

///|
/// `DshRoute`.
pub(all) enum DshRoute {
  Deepseek
  Pi(PiRoute)
}

///|
pub fn PiRoute::json(self : PiRoute) -> J {
  let f = Fields::new()
  f.set_str("name", self.name)
  f.set_str("api", self.api)
  f.set_str("baseURL", self.base_url)
  if self.headers is Some(h) {
    f.set("headers", h.json())
  }
  f.json()
}

///|
pub fn DshRoute::json(self : DshRoute) -> J {
  match self {
    Deepseek => obj([("kind", js("deepseek"))])
    Pi(r) => {
      let f = Fields::of([("kind", js("pi"))])
      f.spread(fields(Some(r.json())))
      f.json()
    }
  }
}

///|
fn session_header() -> Fields {
  Fields::of([("x-opencode-session", js("stillfail-{route}"))])
}

///|
fn dsh_route_of(kind : String, via : Via) -> DshRoute? {
  if kind == "opencode-go" {
    return Some(Pi({ name: "OpenCode Go", api: "openai-completions", base_url: "\{opencode}/v1", headers: Some(session_header()) }))
  }
  if kind == "anthropic-api" {
    return Some(Pi({ name: "Anthropic", api: "anthropic-messages", base_url: "https://api.anthropic.com", headers: None }))
  }
  if kind != "api-provider" {
    return None
  }
  guard api_source(via) is Some((source, at)) else { return None }
  if source.id == "deepseek" {
    return Some(Deepseek)
  }
  let headers = if source.session_header { Some(session_header()) } else { None }
  let pi = (api : String, base : String) => Some(Pi({ name: source.name, api, base_url: base, headers }))
  if at.chat is Some(c) {
    return pi("openai-completions", c)
  }
  if at.anthropic is Some(a) {
    return pi("anthropic-messages", a)
  }
  if at.responses is Some(r) {
    return pi("openai-responses", r)
  }
  None
}

///|
/// `dshRoute`: where a DeepSeek Harness session's model requests go.
pub fn dsh_route(p : J) -> DshRoute? {
  dsh_route_of(access_kind(p), profile_via(p))
}

///|
fn pi_route_of(kind : String, via : Via) -> PiRoute? {
  match dsh_route_of(kind, via) {
    Some(Pi(r)) => Some(r)
    Some(Deepseek) =>
      match api_source(via) {
        Some((source, at)) =>
          match at.chat {
            Some(chat) => Some({ name: source.name, api: "openai-completions", base_url: chat, headers: None })
            None => None
          }
        None => None
      }
    None => None
  }
}

///|
/// `piRoute`: where a Pi session's model requests go.
pub fn pi_route(p : J) -> PiRoute? {
  pi_route_of(access_kind(p), profile_via(p))
}

///|
/// `profileRuntimes`: the runtimes an account runs.
pub fn profile_runtimes(p : J) -> Array[String] {
  let kind = access_kind(p)
  if kind == "service" {
    return []
  }
  if kind == "api-provider" {
    guard api_source(profile_via(p)) is Some((source, at)) else { return [] }
    if kimi_signed_in(p) {
      return ["claude"]
    }
    if source.id == "google-vertex" {
      return ["agy"]
    }
    let out = runtimes_of(at)
    if source.id == "xai" {
      out.push("grok")
    } else if source.id == "google" {
      out.push("agy")
    }
    return out
  }
  if kind == "opencode-go" {
    return ["claude", "codex", "dsh", "pi"]
  }
  if kind == "anthropic-api" {
    return ["claude", "dsh", "pi"]
  }
  let own = runtime_kind(get(Some(p), "runtime"))
  if (own is Some("dsh") || own is Some("pi")) && kind == "subscription" {
    return []
  }
  match own {
    Some(o) => [o]
    None => []
  }
}

///|
/// `profileEnv`: the environment for a profile's processes of `runtime`; none for a runtime it does not run. In values,
/// `{route}` is still to be expanded.
pub fn profile_env(p : J, runtime : String) -> Fields {
  if !profile_runtimes(p).contains(runtime) {
    return Fields::new()
  }
  let key = trim(str_of(get(access(p), "key")).unwrap_or(""))
  let via = profile_via(p)
  let env = access_env(runtime, access_kind(p), key, profile_model(p), via)
  if runtime == "agy" && access_kind(p) == "api-provider" && via.provider is Some("google-vertex") {
    if vertex_account(key) is Some(project) {
      env.set_str("AGY_ADC_AUTH", "1")
      env.set_str("GOOGLE_CLOUD_PROJECT", project)
      env.set_str("GOOGLE_CLOUD_LOCATION", "global")
      env.set_str("GOOGLE_APPLICATION_CREDENTIALS", vertex_key_file(home_of(p)))
    }
  }
  if key_file(p) is Some(_) {
    env.delete("ANTHROPIC_AUTH_TOKEN")
    env.delete("ANTHROPIC_API_KEY")
  }
  let custom = get(Some(p), "env")
  if is_object(custom) {
    // A borrowed profile's without the proxy its host's machine went through (`customEnv`).
    let share = get(Some(p), "share")
    let borrowed = is_object(share) && get(share, "borrowed") is Some(Bool(true))
    env.spread(spread_of(custom).filter(e => !(borrowed && machine_proxy(e.0))))
  }
  env
}

///|
/// `expandRoute`: `{route}` in each value made the session's route.
pub fn expand_route(env : Fields, route : String) -> Fields {
  let out = Fields::new()
  for e in env.entries() {
    match e.1 {
      Str(s) => out.set_str(e.0, replace_all(t(s), "{route}", route))
      other => out.set(e.0, other)
    }
  }
  out
}

///|
/// accounts/profiles.ts `accessKinds`: the access kinds each runtime can use.
pub fn access_kinds(runtime : String) -> Array[String] {
  match runtime {
    "hermes" => ["env"]
    "agy" | "grok" => ["subscription", "api-provider", "env"]
    "claude" => ["subscription", "opencode-go", "anthropic-api", "api-provider", "env"]
    "dsh" | "pi" => ["opencode-go", "anthropic-api", "api-provider", "env"]
    "cursor" | "devin" => ["subscription", "env"]
    _ => ["subscription", "opencode-go", "api-provider", "env"]
  }
}

///|
/// accounts/profiles.ts `keyed`: access kinds that authenticate with a key the profile stores.
pub fn keyed(kind : String) -> Bool {
  kind == "opencode-go" || kind == "anthropic-api" || kind == "api-provider"
}

///|
/// accounts/profiles.ts `runtimesOf`: the runtimes an access kind runs without its provider.
pub fn runtimes_of_kind(kind : String, runtime : String?) -> Array[String] {
  match kind {
    "service" => []
    "opencode-go" => ["claude", "codex", "dsh", "pi"]
    "anthropic-api" => ["claude", "dsh", "pi"]
    "api-provider" => []
    _ =>
      if kind == "subscription" && (runtime == Some("dsh") || runtime == Some("pi")) {
        []
      } else {
        match runtime {
          Some(r) if r != "" => [r]
          _ => []
        }
      }
  }
}
