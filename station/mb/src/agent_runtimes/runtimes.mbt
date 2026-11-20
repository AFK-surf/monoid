// What each runtime's driver starts its process with and how it opens its session: dsh.ts, cursor.ts, pi.ts,
// devin.ts, grok.ts, hermes.ts (their sessions: bridged.mbt, acp_session.mbt). A session's options are runtime.ts
// `OpenOptions` as JSON; `base` the station's environment as it starts what it runs (ops/agent-env.ts `startEnv()`).

///|
/// runtime.ts `OpenOptions`.
pub(all) struct Options {
  key : String
  profile : J
  cwd : String
  resume : String?
  model : String?
  effort : String?
  instructions : String
  skills : String?
  mcp_token : String
  mcp_url : String
  route : String
}

///|
pub fn Options::of(v : J) -> Options {
  let o = Some(v)
  {
    key: said(get(o, "key")),
    profile: get(o, "profile").unwrap_or(obj([])),
    cwd: said(get(o, "cwd")),
    resume: str_of(get(o, "resume")),
    model: str_of(get(o, "model")),
    effort: str_of(get(o, "effort")),
    instructions: str_of(get(o, "instructions")).unwrap_or(""),
    skills: str_of(get(o, "skills")),
    mcp_token: str_of(get(o, "mcpToken")).unwrap_or(""),
    mcp_url: str_of(get(o, "mcpUrl")).unwrap_or(""),
    route: str_of(get(o, "route")).unwrap_or(""),
  }
}

///|
fn Options::home(self : Options) -> String {
  home_of(self.profile)
}

///|
/// `options.model ?? profileModel(options.profile)`.
pub fn Options::chosen_model(self : Options) -> String? {
  match self.model {
    Some(m) => Some(m)
    None => profile_model(self.profile)
  }
}

///|
/// A runtime's environment: the station's less what it scrubs, the profile's for `runtime` with its route, this
/// machine kept out of a proxy either names (`keepLocal`).
fn runtime_env(base : Fields, scrubbed : Array[String], options : Options, runtime : String) -> Fields {
  let env = clean_env(base, scrubbed)
  spread_env(env, expand_route(profile_env(options.profile, runtime), options.route))
  keep_local_fields(env)
  env
}

///|
/// `new URL(base).hostname === "api.openai.com"` (none where it is no URL).
fn openai_own(base_url : String) -> Bool {
  let at = index_of(base_url, "://")
  if at <= 0 {
    return false
  }
  let rest = sub(base_url, at + 3)
  let mut end = rest.length()
  for c in ["/", "?", "#"] {
    let i = index_of(rest, c)
    if i >= 0 && i < end {
      end = i
    }
  }
  let authority = sub(rest, 0, to=end)
  let host_port = match authority.rev_find("@") {
    Some(i) => sub(authority, i + 1)
    None => authority
  }
  let host = match host_port.rev_find(":") {
    Some(i) if !host_port.has_prefix("[") => sub(host_port, 0, to=i)
    _ => host_port
  }
  lower(host) == "api.openai.com"
}

///|
/// What the model catalog says of a model (accounts/catalog.ts `facts`: its window and most output) and whether it
/// reads images (accounts/models.ts `seesImages`): given, as the catalog is the station's.
pub(all) struct ModelFacts {
  context : Double?
  output : Double?
  sees_images : Bool
}

///|
fn int_positive(v : Double?) -> Double? {
  match v {
    Some(n) if finite(n) && n.floor() == n && n > 0.0 => Some(n)
    _ => None
  }
}

// ── DeepSeek Harness ─────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let dsh_scrubbed : Array[String] = [
  "DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL", "STILLFAIL_DSH_KEY", "DSH_HOME", "DSH_AGENTS_HOME", "DSH_PERMISSION_MODE",
]

///|
/// dsh.ts `SESSIONS`.
pub let dsh_sessions : String = "dsh-sessions"

///|
let dsh_tools : String = "stillfail-tools"

///|
let dsh_token_header : String = "__stillfail_mcp_authorization__"

///|
fn pi_effort(effort : String?) -> String? {
  match effort {
    Some(e) if ["minimal", "low", "medium", "high", "xhigh", "max"].contains(e) => Some(e)
    _ => None
  }
}

///|
fn deepseek_effort(effort : String?) -> String? {
  match effort {
    Some("low") => Some("low")
    Some("medium") | Some("high") => Some("high")
    Some("max") => Some("max")
    _ => None
  }
}

///|
/// `literal`: dsh's prompt variables are `{{name}}`, strictly: any `{{` in the instructions is broken.
fn dsh_literal(text : String) -> String {
  replace_all(text, "{{", "{\u{200b}{")
}

///|
/// `dshSetup`: the patch over dsh's acp profile for a session and the route its agent asks for. Its refusal where the
/// route needs a model and none is named.
pub fn dsh_setup(
  route : DshRoute?,
  model : String?,
  effort : String?,
  instructions : String,
  home : String,
  session_route : String,
  mcp_url : String,
  bridge : String,
  facts : ModelFacts?,
) -> Result[J, String] {
  let tools = obj([
    ("transport", js("streamable-http")),
    ("serverName", js("stillfail")),
    ("url", js(mcp_url)),
    ("headers", obj([("Authorization", js(dsh_token_header))])),
    ("failOnStartupError", Bool(true)),
  ])
  let patch : Array[J] = [
    obj([("id", js("acp")), ("disabled", Bool(true))]),
    obj([
      (
        "insert",
        Arr([
          obj([("id", js("stillfail-bridge")), ("name", js(bridge)), ("config", obj([("tools", js(dsh_tools))]))]),
          obj([("id", js(dsh_tools)), ("name", js("@deepseek-ai/dsh-mcp-client")), ("config", tools)]),
        ]),
      ),
    ]),
  ]
  let mut chosen : (String, String)? = None
  let mut chosen_effort : String? = None
  match route {
    Some(Pi(r)) => {
      guard model is Some(m) else { return Err("the profile names no model for DeepSeek Harness") }
      let entry = Fields::of([("id", js(m))])
      let known = facts.unwrap_or({ context: None, output: None, sees_images: false })
      if known.sees_images {
        entry.set("input", arr_of(["text", "image"]))
      }
      if int_positive(known.context) is Some(window) {
        entry.set("contextWindow", num(window))
        if int_positive(known.output) is Some(out) && out < window {
          entry.set("maxTokens", num(out))
        }
      }
      let provider = Fields::of([
        ("displayName", js(r.name)),
        ("api", js(r.api)),
        ("baseURL", js(r.base_url)),
        ("apiKeyEnv", js(dsh_key)),
      ])
      if r.headers is Some(h) {
        provider.set("headers", expand_route(h, session_route).json())
      }
      if r.api != "anthropic-messages" && !openai_own(r.base_url) {
        provider.set("compat", obj([("supportsDeveloperRole", Bool(false))]))
      }
      let reasoning = pi_effort(effort)
      chosen_effort = reasoning
      if reasoning is Some(level) {
        provider.set_str("reasoning", level)
        entry.set("reasoningEfforts", Fields::of([("off", Null), (level, js(level))]).json())
      }
      provider.set("models", Arr([entry.json()]))
      // (models in its place: before headers, compat and reasoning, as the object literal had it)
      let ordered = Fields::new()
      for k in ["displayName", "api", "baseURL", "apiKeyEnv", "models", "headers", "compat", "reasoning"] {
        if provider.get(k) is Some(v) {
          ordered.set(k, v)
        }
      }
      patch.push(obj([("id", js("llm-pi-ai")), ("config", obj([("providers", obj([("stillfail", ordered.json())]))]))]))
      chosen = Some(("stillfail", m))
    }
    Some(Deepseek) => {
      let config = Fields::of([("apiKeyEnv", js("DEEPSEEK_API_KEY"))])
      if model is Some(m) {
        config.set("models", Arr([obj([("id", js(m))])]))
      }
      let reasoning = deepseek_effort(effort)
      chosen_effort = reasoning
      if reasoning is Some(level) {
        config.set_str("reasoningEffort", level)
      }
      patch.push(obj([("id", js("llm-deepseek")), ("config", config.json())]))
      chosen = Some(("deepseek-official", model.unwrap_or("deepseek-v4-flash")))
    }
    None => if model is Some(m) { chosen = Some(("deepseek-official", m)) }
  }
  if chosen is Some((provider, m)) {
    patch.push(obj([("id", js("agent-default-model")), ("config", obj([("provider", js(provider)), ("model", js(m))]))]))
  }
  patch.push(obj([("id", js("system-prompt")), ("config", obj([("personaPrefix", js("")), ("personaSuffix", js(dsh_literal(instructions)))]))]))
  patch.push(
    obj([("id", js("session-persistence-jsonl")), ("config", obj([("root", js(join([home, dsh_sessions]))), ("compression", js("none"))]))]),
  )
  let out = Fields::of([("patch", Arr(patch))])
  if chosen is Some((provider, m)) {
    out.set_str("provider", provider)
    out.set_str("model", m)
    if chosen_effort is Some(e) {
      out.set_str("effort", e)
    }
  }
  Ok(out.json())
}

///|
/// `patchText`: the patch as its file says it, the tools' header read from the environment by dsh.
pub fn patch_text(patch : J) -> String {
  replace_first(
    @jsjson.stringify_indent(patch, 2),
    "\"\{dsh_token_header}\"",
    "!!js \"'Bearer ' + process.env.STILLFAIL_MCP_TOKEN\"",
  ) +
  "\n"
}

///|
/// `sessionDir`: where dsh keeps a session (<root>/<cwd>/<id>), if it is there.
pub async fn dsh_session_dir(host : @host.Host, home : String, session_id : String) -> String? {
  let root = join([home, dsh_sessions])
  guard read_names(host, root) is Some(dirs) else { return None }
  for d in dirs {
    let dir = join([root, d, session_id])
    if stat_kind(host, dir) is Some("dir") {
      return Some(dir)
    }
  }
  None
}

///|
/// What a runtime is started with and asked first (`command`, `args`, `env`, the files written for it, and its
/// opening's request or ACP's `meta` and `opening`).
pub(all) struct Start {
  command : String
  args : Array[String]
  env : Fields
  files : Array[(String, String)]
  open : J?
  meta : J?
  opening : J?
  init_timeout : Double?
}

///|
pub fn Start::json(self : Start) -> J {
  let f = Fields::of([("command", js(self.command)), ("args", arr_of(self.args)), ("env", self.env.json())])
  f.set("files", Arr(self.files.map(x => Arr([js(x.0), js(x.1)]))))
  for e in [("open", self.open), ("meta", self.meta), ("opening", self.opening)] {
    if e.1 is Some(v) {
      f.set(e.0, v)
    }
  }
  if self.init_timeout is Some(ms) {
    f.set("initializeTimeoutMs", num(ms))
  }
  f.json()
}

///|
/// `DshDriver.open` up to its process: its patch written (mode 0600), its arguments, environment and opening request.
pub async fn dsh_start(
  host : @host.Host,
  options : Options,
  base : Fields,
  command : String,
  bridge : String,
  facts : ModelFacts?,
) -> Start raise {
  let home = options.home()
  make_dir(host, home)
  if options.resume is Some(id) && dsh_session_dir(host, home, id) is None {
    raise FsError("no dsh session \{id}")
  }
  let model = options.chosen_model()
  let setup = match
    dsh_setup(dsh_route(options.profile), model, options.effort, options.instructions, home, options.route, options.mcp_url, bridge, facts) {
    Ok(s) => s
    Err(why) => raise FsError(why)
  }
  let dir = join([home, "stillfail"])
  make_dir(host, dir)
  let patch_file = join([dir, "\{sub(sha256_hex(options.key), 0, to=16)}.patch.yml"])
  let text = patch_text(get(Some(setup), "patch").unwrap_or(Arr([])))
  write_file(host, patch_file, text, mode=0o600)
  let env = runtime_env(base, dsh_scrubbed, options, "dsh")
  env.set_str("DSH_HOME", home)
  env.set_str("DSH_AGENTS_HOME", join([home, "agents"]))
  env.set_str("DSH_PERMISSION_MODE", "danger-full-access")
  env.or_set("DSH_TELEMETRY_MODE", "DISABLED")
  env.set_str("STILLFAIL_PEER_HTTP", peer_http_base(options.mcp_url))
  env.set_str("STILLFAIL_MCP_TOKEN", options.mcp_token)
  let open = Fields::of([("cwd", js(options.cwd))])
  if options.resume is Some(r) {
    open.set_str("resume", r)
  }
  if get(Some(setup), "provider") is Some(p) {
    open.set("provider", p)
    open.set("model", get(Some(setup), "model").unwrap_or(Null))
  }
  if get(Some(setup), "effort") is Some(e) {
    open.set("effort", e)
  }
  {
    command,
    args: ["--profile", "acp", "--patch", patch_file],
    env,
    files: [(patch_file, text)],
    open: Some(open.json()),
    meta: None,
    opening: None,
    init_timeout: None,
  }
}

///|
/// What dsh's answer to `open` makes of its opening: the session it named, or why it did not (its refusal for the
/// station's tools said in the station's words, `no_tools`).
pub fn dsh_opened(answer : J, no_tools : String) -> Result[String, String] {
  let a = Some(answer)
  match get(a, "error") {
    Some(Str(e)) => return Err(if is_s(get(a, "lacks"), "tools") { no_tools } else { "dsh open: \{t(e)}" })
    _ => ()
  }
  match get(a, "session") {
    Some(Str(s)) if s.length() > 0 => Ok(t(s))
    _ => Err("dsh named no session")
  }
}

// ── Cursor ───────────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let cursor_scrubbed : Array[String] = [
  "CURSOR_API_KEY", "CURSOR_AUTH_TOKEN", "CURSOR_BACKEND_URL", "CURSOR_WEBSITE_URL", "STILLFAIL_CURSOR_SDK", "STILLFAIL_CURSOR_HOME",
]

///|
pub let cursor_sdk_package : String = "@cursor/sdk"

///|
pub fn cursor_home(home : String) -> String {
  join([home, "cursor"])
}

///|
pub let cursor_sessions : String = "sessions"

///|
pub let cursor_sdk_home : String = "home"

///|
pub fn cursor_sdk_prefix(data : String) -> String {
  join([data, "runtimes", "cursor"])
}

///|
fn cursor_sdk_roots(data : String) -> Array[String] {
  [join([cursor_sdk_prefix(data), "lib", "node_modules"]), join([cursor_sdk_prefix(data), "node_modules"])]
}

///|
/// `findSdk`: the SDK's package under the prefix, none when it is not installed.
pub async fn cursor_find_sdk(host : @host.Host, data : String) -> String? {
  for root in cursor_sdk_roots(data) {
    let dir = join([root, "@cursor", "sdk"])
    if exists(host, join([dir, "package.json"])) {
      return Some(dir)
    }
  }
  None
}

///|
/// `sdkVersionSoon`: the SDK's version as its package says.
pub async fn cursor_sdk_version(host : @host.Host, data : String) -> String? {
  for root in cursor_sdk_roots(data) {
    guard read_text(host, join([root, "@cursor", "sdk", "package.json"])) is Some(text) else { continue }
    return str_of(get(parse(text), "version"))
  }
  None
}

///|
/// `cursorKey` of its auth.json's text.
pub fn cursor_key_of(text : String?) -> String? {
  match text {
    Some(t0) => nonempty(get(parse(t0), "apiKey"))
    None => None
  }
}

///|
/// `CursorDriver.open` up to its process (`sdk`: its package; `node` the Node the bridge runs on).
pub async fn cursor_start(
  host : @host.Host,
  options : Options,
  base : Fields,
  node : String,
  bridge : String,
  sdk : String?,
  data : String,
) -> Start raise {
  let home = options.home()
  let sessions = join([cursor_home(home), cursor_sessions])
  make_dir(host, sessions)
  let package = match sdk {
    Some(s) => Some(s)
    None => cursor_find_sdk(host, data)
  }
  guard package is Some(sdk_dir) else { raise FsError("the runner did not start: cursor is not on PATH") }
  if options.resume is Some(id) && !exists(host, join([sessions, "\{id}.jsonl"])) {
    raise FsError("no Cursor session \{id}")
  }
  let model = options.chosen_model()
  let rules = rules_folder(
    host,
    cursor_home(home),
    options.key,
    ".cursor",
    "stillfail.mdc",
    cursor_rule(options.instructions),
    skills?=options.skills,
  )
  let env = runtime_env(base, cursor_scrubbed, options, "cursor")
  let key = cursor_key_of(read_text(host, join([cursor_home(home), "auth.json"])))
  if key is Some(k) && !env.has("CURSOR_API_KEY") {
    env.set_str("CURSOR_API_KEY", k)
  }
  env.set_str("STILLFAIL_CURSOR_SDK", sdk_dir)
  env.set_str("STILLFAIL_CURSOR_HOME", join([cursor_home(home), cursor_sessions, cursor_sdk_home]))
  env.set_str("STILLFAIL_MCP_TOKEN", options.mcp_token)
  env.set_str("STILLFAIL_PEER_HTTP", peer_http_base(options.mcp_url))
  let open = Fields::of([("cwd", js(options.cwd))])
  if options.resume is Some(r) {
    open.set_str("resume", r)
  }
  if model is Some(m) {
    open.set_str("model", m)
  }
  open.set_str("mcpUrl", options.mcp_url)
  open.set_str("rules", rules)
  open.set_str("sessions", sessions)
  {
    command: node,
    args: [bridge],
    env,
    files: [(join([rules, ".cursor", "rules", "stillfail.mdc"]), cursor_rule(options.instructions))],
    open: Some(open.json()),
    meta: None,
    opening: None,
    init_timeout: None,
  }
}

// ── Pi ───────────────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let pi_scrubbed : Array[String] = [
  "PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR", "PI_SESSION_ID", "PI_SESSION_FILE", "STILLFAIL_PI_KEY", "STILLFAIL_PI_SETUP",
]

///|
pub fn pi_home(home : String) -> String {
  join([home, "pi"])
}

///|
pub let pi_sessions : String = "sessions"

///|
pub fn pi_session_file(home : String, id : String) -> String {
  join([pi_home(home), pi_sessions, "\{id}.jsonl"])
}

///|
/// `piProvider`: the provider as Pi's `registerProvider` takes it.
pub fn pi_provider(route : PiRoute, model : String, effort : String?, session_route : String, facts : ModelFacts?) -> J {
  let known = facts.unwrap_or({ context: None, output: None, sees_images: false })
  let entry = Fields::of([
    ("id", js(model)),
    ("name", js(model)),
    ("reasoning", Bool(effort is Some(_))),
    ("input", arr_of(if known.sees_images { ["text", "image"] } else { ["text"] })),
    ("cost", obj([("input", int(0)), ("output", int(0)), ("cacheRead", int(0)), ("cacheWrite", int(0))])),
  ])
  if int_positive(known.context) is Some(w) {
    entry.set("contextWindow", num(w))
  }
  match int_positive(known.output) {
    Some(out) =>
      match known.context {
        None => entry.set("maxTokens", num(out))
        Some(w) => if out < w { entry.set("maxTokens", num(out)) }
      }
    None => ()
  }
  let provider = Fields::of([
    ("name", js(route.name)),
    ("baseUrl", js(route.base_url)),
    ("api", js(route.api)),
    ("apiKey", js("$\{pi_key}")),
    ("models", Arr([entry.json()])),
  ])
  if route.headers is Some(h) {
    provider.set("headers", expand_route(h, session_route).json())
  }
  if route.api != "anthropic-messages" && !openai_own(route.base_url) {
    provider.set("compat", obj([("supportsDeveloperRole", Bool(false))]))
  }
  provider.json()
}

///|
/// `piSetup`: the process's arguments and its extension's setup. Its refusal where the route needs a model.
pub fn pi_setup(
  route : PiRoute?,
  model : String?,
  options : Options,
  file : String,
  instructions : String?,
  bridge : String,
  facts : ModelFacts?,
) -> Result[(Array[String], J), String] {
  let args = ["--mode", "rpc", "--offline", "--no-extensions", "-e", "builtin:mcp", "-e", bridge, "--no-approve", "--no-skills", "--session", file]
  if options.skills is Some(s) {
    args.push_iter(["--skill", s].iter())
  }
  if instructions is Some(i) {
    args.push_iter(["--append-system-prompt", i].iter())
  }
  let setup = Fields::of([("tools", obj([("url", js(options.mcp_url))]))])
  match route {
    Some(r) => {
      guard model is Some(m) else { return Err("the profile names no model for Pi") }
      setup.set("provider", pi_provider(r, m, options.effort, options.route, facts))
      args.push_iter(["--model", "stillfail/\{m}"].iter())
    }
    None => if model is Some(m) { args.push_iter(["--model", m].iter()) }
  }
  if options.effort is Some(e) && ["minimal", "low", "medium", "high", "xhigh", "max"].contains(e) {
    args.push_iter(["--thinking", e].iter())
  }
  Ok((args, setup.json()))
}

///|
/// `PiDriver.open` up to its process: its instructions' file (mode 0600, none for no instructions), arguments,
/// environment; `id` the session's (the resumed one's, else a new one's).
pub async fn pi_start(
  host : @host.Host,
  options : Options,
  base : Fields,
  command : String,
  bridge : String,
  id : String,
  facts : ModelFacts?,
) -> Start raise {
  let home = options.home()
  let dir = pi_home(home)
  make_dir(host, join([dir, pi_sessions]))
  let file = pi_session_file(home, id)
  if options.resume is Some(r) && stat_kind(host, file) != Some("file") {
    raise FsError("no Pi session \{r}")
  }
  let files = []
  let instructions = if options.instructions != "" {
    let own = join([dir, "stillfail"])
    make_dir(host, own)
    let path = join([own, "\{sub(sha256_hex(options.key), 0, to=16)}.md"])
    write_file(host, path, options.instructions, mode=0o600)
    files.push((path, options.instructions))
    Some(path)
  } else {
    None
  }
  let (args, setup) = match pi_setup(pi_route(options.profile), options.chosen_model(), options, file, instructions, bridge, facts) {
    Ok(x) => x
    Err(why) => raise FsError(why)
  }
  let env = runtime_env(base, pi_scrubbed, options, "pi")
  env.set_str("PI_CODING_AGENT_DIR", dir)
  env.set_str("PI_TELEMETRY", "0")
  env.set_str("PI_SKIP_VERSION_CHECK", "1")
  env.set_str("STILLFAIL_PI_SETUP", stringify(setup))
  env.set_str("STILLFAIL_PEER_HTTP", peer_http_base(options.mcp_url))
  env.set_str("STILLFAIL_MCP_TOKEN", options.mcp_token)
  { command, args, env, files, open: Some(obj([])), meta: None, opening: None, init_timeout: None }
}

// ── Devin ────────────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let devin_scrubbed : Array[String] = [
  "WINDSURF_API_KEY", "WINDSURF_API_SERVER_URL", "DEVIN_API_URL", "DEVIN_WEBAPP_URL", "DEVIN_MODEL", "DEVIN_SESSIONS_DIR", "DEVIN_PERMISSION_MODE",
  "DEVIN_SANDBOX", "ACP_BACKEND",
]

///|
pub fn devin_home(home : String) -> String {
  join([home, "devin"])
}

///|
pub fn devin_data(home : String) -> String {
  join([devin_home(home), "data"])
}

///|
pub let devin_sessions : String = "sessions"

///|
pub let devin_store : String = "store"

///|
/// `devinKey` of its credentials.toml's text: `/^\s*windsurf_api_key\s*=\s*"([^"]+)"/m`.
pub fn devin_key_of(text : String?) -> String? {
  guard text is Some(all) else { return None }
  // A line begins at the start or after \n, \r, U+2028 or U+2029 (`m`).
  let starts = [0]
  for i in 0..<all.length() {
    let c = all.unsafe_charcode_at(i)
    if c == 0x0a || c == 0x0d || c == 0x2028 || c == 0x2029 {
      starts.push(i + 1)
    }
  }
  for start in starts {
    // (`\s*` may run over line ends: the match is tried at each line's start, as the regex's `^` tries it)
    let mut i = start
    while i < all.length() && is_space(all.unsafe_charcode_at(i)) {
      i += 1
    }
    let name = "windsurf_api_key"
    if sub(all, i, to=i + name.length()) != name {
      continue
    }
    i += name.length()
    while i < all.length() && is_space(all.unsafe_charcode_at(i)) {
      i += 1
    }
    if i >= all.length() || all.unsafe_charcode_at(i) != '='.to_int() {
      continue
    }
    i += 1
    while i < all.length() && is_space(all.unsafe_charcode_at(i)) {
      i += 1
    }
    if i >= all.length() || all.unsafe_charcode_at(i) != '"'.to_int() {
      continue
    }
    let end = index_of(all, "\"", from=i + 1)
    if end > i + 1 {
      return Some(sub(all, i + 1, to=end))
    }
  }
  None
}

///|
/// `CONFIG`: the configuration Devin is started with.
pub fn devin_config() -> J {
  obj([
    (
      "read_config_from",
      obj([
        ("cursor", Bool(false)),
        ("windsurf", Bool(false)),
        ("claude", Bool(false)),
        ("opencode", Bool(false)),
        ("zed", Bool(false)),
        ("copilot", Bool(false)),
        ("cloud", Bool(false)),
      ]),
    ),
    ("auto_update", Bool(false)),
    ("typewriter", Bool(false)),
  ])
}

///|
/// `LEVELS`: the thinking levels Devin's models are offered at.
pub let devin_levels : Array[String] = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

///|
/// `AGY_LEVELS`: the thinking levels Antigravity's models append to a family's name.
pub let agy_levels : Array[String] = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

///|
/// model.ts `splitAgyTier`: an Antigravity tiered id split into its model and level.
pub fn split_agy_tier(id : String) -> (String, String)? {
  let trimmed = trim(id)
  for l in agy_levels {
    if trimmed.has_suffix("-\{l}") && trimmed.length() > l.length() + 1 {
      return Some((sub(trimmed, 0, to=trimmed.length() - l.length() - 1), l))
    }
  }
  None
}

///|
/// agy.ts `agyBaseModel`: a raw ACP `modelId` split into its base model and thinking level.
pub fn agy_base_model(id : String) -> (String, String?) {
  match split_agy_tier(id) {
    Some((m, l)) => (m, Some(l))
    None => (trim(id), None)
  }
}

///|
/// `splitDevinFusion`: a Fusion pairing's lead (and its effort) and sidekick.
pub(all) struct Fusion {
  lead : String
  effort : String?
  side : String
}

///|
pub fn split_devin_fusion(id : String) -> Fusion? {
  let s = lower(trim(id))
  if !s.has_prefix("fusion-") {
    return None
  }
  let at = index_of(s, "-sidekick-", from=7)
  if at < 0 {
    return None
  }
  let raw_lead = sub(s, 7, to=at)
  let side = sub(s, at + 10)
  if raw_lead == "" || side == "" {
    return None
  }
  let mut effort = None
  for l in devin_levels {
    if raw_lead.has_suffix("-\{l}") && raw_lead.length() > l.length() + 1 {
      effort = Some(l)
      break
    }
  }
  let lead = match effort {
    Some(e) => sub(raw_lead, 0, to=raw_lead.length() - e.length() - 1)
    None => raw_lead
  }
  Some({ lead, effort, side })
}

///|
/// `devinFusionBase`: a model as the station keeps it, a Fusion pairing's lead without its effort.
pub fn devin_fusion_base(id : String) -> (String, String?) {
  match split_devin_fusion(id) {
    Some(s) => ("fusion-\{s.lead}-sidekick-\{s.side}", s.effort)
    None => (id, None)
  }
}

///|
/// `variant`: a model and level as Devin names the variant.
pub fn devin_variant(model : String, effort : String?) -> String {
  match split_devin_fusion(model) {
    Some(s) => {
      let level = match effort {
        Some(e) if devin_levels.contains(e) => e
        _ => s.effort.unwrap_or("high")
      }
      "fusion-\{s.lead}-\{level}-sidekick-\{s.side}"
    }
    None =>
      match effort {
        Some(e) if devin_levels.contains(e) => "\{model}-\{e}"
        _ => model
      }
  }
}

///|
/// `expandDevinFusion`: the pairings a catalog's Fusion offers.
pub fn expand_devin_fusion(fusion : J?) -> Array[String] {
  let out = []
  guard present(fusion) is Some(_) else { return out }
  let sides = arr(get(fusion, "sides"))
  for e in fields(get(fusion, "leads")) {
    let lead = match split_devin_fusion("fusion-\{e.0}-sidekick-x") {
      Some(s) => s.lead
      None => e.0
    }
    for i in arr(Some(e.1)) {
      let side = match i {
        Num(n) if n >= 0.0 && n.floor() == n && n < sides.length().to_double() => sides[n.to_int()]
        _ => Null
      }
      if side is Str(s) && s.length() > 0 {
        let m = "fusion-\{lead}-sidekick-\{t(s)}"
        if !out.contains(m) {
          out.push(m)
        }
      }
    }
  }
  out
}

///|
fn ends_billed_apart(uid : String) -> Bool {
  uid.has_suffix("-fast") || uid.has_suffix("-priority") || uid.has_suffix("-lightning")
}

///|
/// `devinCatalog`: the models `devin models list --format json` lists, as the station offers them.
pub fn devin_catalog(listed : J?) -> J {
  let models : Array[String] = []
  let efforts = Fields::new()
  let sides : Array[String] = []
  let leads = Fields::new()
  for family in arr(get(listed, "families")) {
    let seen : Array[(String, String?)] = []
    for v in arr(get(Some(family), "variants")) {
      let uid = str_of(get(Some(v), "model_uid")).unwrap_or("")
      if uid == "" || ends_billed_apart(uid) {
        continue
      }
      if uid.has_prefix("fusion-") && uid.contains("-sidekick-") {
        if !uid.contains("-fast-sidekick-") && !uid.contains("-priority-sidekick-") && !uid.contains("-lightning-sidekick-") {
          if split_devin_fusion(uid) is Some(split) {
            let idx = match sides.search(split.side) {
              Some(i) => i
              None => {
                sides.push(split.side)
                sides.length() - 1
              }
            }
            let list = arr(leads.get(split.lead))
            if !list.iter().any(x => x is Num(n) && n == idx.to_double()) {
              leads.set(split.lead, Arr(list + [int(idx)]))
            }
          }
        }
        continue
      }
      if uid.contains("-sidekick-") {
        continue
      }
      let mut level = None
      for l in devin_levels {
        if uid.has_suffix("-\{l}") {
          level = Some(l)
          break
        }
      }
      seen.push(
        (
          match level {
            Some(l) => sub(uid, 0, to=uid.length() - l.length() - 1)
            None => uid
          },
          level,
        ),
      )
    }
    let count = (m : String) => seen.filter(s => s.0 == m).length()
    let mut best : String? = None
    for s in seen {
      match best {
        None => best = Some(s.0)
        Some(b) => if count(s.0) > count(b) { best = Some(s.0) }
      }
    }
    guard best is Some(model) && !models.contains(model) else { continue }
    models.push(model)
    let levels = devin_levels.filter(l => seen.iter().any(s => s.0 == model && s.1 == Some(l)))
    if levels.length() > 0 {
      efforts.set(model, arr_of(levels))
    }
  }
  obj([
    ("models", arr_of(models)),
    ("efforts", efforts.json()),
    ("fusion", if sides.length() > 0 { obj([("leads", leads.json()), ("sides", arr_of(sides))]) } else { Null }),
  ])
}

///|
/// `callOf`: a model call's counts as Devin says them, as the transcript keeps them.
pub fn devin_call_of(update : J?) -> J {
  let meta = match get(update, "_meta") {
    None | Some(Null) => None
    m => m
  }
  let read = finite_or_zero(get(meta, "cognition.ai/cachedReadTokens"))
  let input = finite_or_zero(get(meta, "cognition.ai/inputTokens")) - read
  obj([
    ("inputTokens", num(if input > 0.0 { input } else { 0.0 })),
    ("cacheReadTokens", num(read)),
    ("cacheWriteTokens", int(0)),
    ("outputTokens", num(finite_or_zero(get(meta, "cognition.ai/outputTokens")))),
  ])
}

///|
/// `devinArgs`.
pub fn devin_args(config : String, model : String?, effort : String?) -> Array[String] {
  let args = ["--config", config, "acp"]
  if model is Some(m) {
    args.push_iter(["--model", devin_variant(m, effort)].iter())
  }
  args
}

///|
/// `devinEnv`.
pub fn devin_env(options : Options, base : Fields) -> Fields {
  let env = runtime_env(base, devin_scrubbed, options, "devin")
  env.set_str("DEVIN_SESSIONS_DIR", join([devin_home(options.home()), devin_sessions, devin_store]))
  env.set_str("STILLFAIL_PEER_HTTP", peer_http_base(options.mcp_url))
  env
}

///|
/// `DevinDriver.starting`: its configuration and instructions' folder written, a session it would not find refused.
pub async fn devin_start(host : @host.Host, options : Options, base : Fields, command : String) -> Start raise {
  let home = options.home()
  let sessions = join([devin_home(home), devin_sessions])
  make_dir(host, join([sessions, devin_store]))
  if options.resume is Some(id) && !exists(host, join([sessions, "\{id}.jsonl"])) {
    raise FsError("no Devin session \{id}")
  }
  let config = join([devin_home(home), "config.json"])
  let text = "\{@jsjson.stringify_indent(devin_config(), 2)}\n"
  write_file(host, config, text)
  let rules = rules_folder(host, devin_home(home), options.key, ".devin", "stillfail.md", devin_rule(options.instructions), skills?=options.skills)
  {
    command,
    args: devin_args(config, options.chosen_model(), options.effort),
    env: devin_env(options, base),
    files: [(config, text), (join([rules, ".devin", "rules", "stillfail.md"]), devin_rule(options.instructions))],
    open: None,
    meta: None,
    opening: Some(obj([("additionalDirectories", arr_of([rules]))])),
    init_timeout: None,
  }
}

///|
/// `DevinDriver.initialized`'s key: the profile's sign-in's.
pub async fn devin_key(host : @host.Host, home : String) -> String? {
  devin_key_of(read_text(host, join([devin_data(home), "devin", "credentials.toml"])))
}

// ── Grok Build ───────────────────────────────────────────────────────────────────────────────────────────────────

///|
pub let grok_scrubbed : Array[String] = [
  "XAI_API_KEY", "GROK_CODE_XAI_API_KEY", "GROK_HOME", "GROK_AUTH", "GROK_AUTH_PATH", "GROK_AUTH_PROVIDER_COMMAND", "GROK_CONFIG", "GROK_CONFIG_PATH",
  "GROK_DEFAULT_MODEL", "GROK_AGENT_SECRET", "GROK_SANDBOX",
]

///|
pub fn grok_home(home : String) -> String {
  join([home, "grok"])
}

///|
pub let grok_sessions : String = "sessions"

///|
pub let grok_transcript : String = "chat_history.jsonl"

///|
pub let grok_usage : String = "stillfail-usage.jsonl"

///|
/// `grokEffort`.
pub fn grok_effort(effort : String?) -> String? {
  match effort {
    Some(e) if ["low", "medium", "high", "xhigh", "max"].contains(e) => Some(e)
    _ => None
  }
}

///|
/// `usageLine`: a turn's usage as the station keeps it beside the transcript (none without its usage or its id).
pub fn grok_usage_line(answer : J?, time : Double, window : J) -> String? {
  let meta = get(get(answer, "result"), "_meta")
  let u = get(meta, "usage")
  guard is_object(u) else { return None }
  let read = finite_or_zero(get(u, "cachedReadTokens"))
  let written = finite_or_zero(get(u, "cacheCreationTokens"))
  let input = finite_or_zero(get(u, "inputTokens")) - read - written
  let usage = obj([
    ("input", num(if input > 0.0 { input } else { 0.0 })),
    ("cacheRead", num(read)),
    ("cacheWrite", num(written)),
    ("output", num(finite_or_zero(get(u, "outputTokens")))),
    ("calls", num(finite_or_zero(get(u, "modelCalls")))),
  ])
  let id = match (get(meta, "promptId"), get(meta, "requestId")) {
    (Some(Str(p)), _) => t(p)
    (_, Some(Str(r))) => t(r)
    _ => return None
  }
  let model : J = match get(meta, "modelId") {
    Some(Str(m)) => Str(m)
    _ => Null
  }
  Some(
    stringify(
      obj([
        ("type", js("stillfail/usage")),
        ("time", num(time)),
        ("id", js(id)),
        ("model", model),
        ("usage", usage),
        ("context", num(finite_or_zero(get(meta, "totalTokens")))),
        ("window", window),
      ]),
    ),
  )
}

///|
/// `sessionAt`: where Grok Build keeps a session (<grok home>/sessions/<cwd>/<id>), if it is there.
pub async fn grok_session_at(host : @host.Host, home : String, session_id : String) -> String? {
  if session_id == "" {
    return None
  }
  let root = join([grok_home(home), grok_sessions])
  guard read_names(host, root) is Some(dirs) else { return None }
  for d in dirs {
    let dir = join([root, d, session_id])
    if stat_kind(host, dir) is Some("dir") {
      return Some(dir)
    }
  }
  None
}

///|
/// GrokSession `keepUsage`'s write: the line beside the session's transcript, where it is.
pub async fn grok_keep_usage(host : @host.Host, home : String, session_id : String, line : String) -> Unit {
  guard grok_session_at(host, home, session_id) is Some(dir) else { return }
  try append_file(host, join([dir, grok_usage]), "\{line}\n") catch {
    _ => ()
  }
}

///|
/// `grokRules`.
pub fn grok_rules(instructions : String) -> String {
  "\{instructions}\{if instructions == "" { "" } else { "\n\n" }}The station's tools (chat_post, chat_state and the others named in these instructions) are the stillfail MCP server's: call one with use_tool and its full name, stillfail__<tool> (for example stillfail__chat_post), without searching for it first."
}

///|
/// `grokArgs`.
pub fn grok_args(model : String?, effort : String?) -> Array[String] {
  let args = ["agent", "--always-approve", "--no-leader"]
  if model is Some(m) {
    args.push_iter(["--model", m].iter())
  }
  if grok_effort(effort) is Some(e) {
    args.push_iter(["--reasoning-effort", e].iter())
  }
  args.push("stdio")
  args
}

///|
/// `grokEnv`.
pub fn grok_env(options : Options, base : Fields) -> Fields {
  let env = runtime_env(base, grok_scrubbed, options, "grok")
  env.set_str("GROK_HOME", grok_home(options.home()))
  env.set_str("GROK_DISABLE_AUTOUPDATER", "1")
  env.or_set("GROK_TELEMETRY_ENABLED", "0")
  env.or_set("GROK_TELEMETRY_TRACE_UPLOAD", "0")
  for vendor in ["CLAUDE", "CURSOR"] {
    for cell in ["SKILLS", "RULES", "AGENTS", "MCPS", "HOOKS", "SESSIONS"] {
      env.set_str("GROK_\{vendor}_\{cell}_ENABLED", "false")
    }
  }
  env.set_str("STILLFAIL_PEER_HTTP", peer_http_base(options.mcp_url))
  env
}

///|
/// `GrokDriver.starting`.
pub async fn grok_start(host : @host.Host, options : Options, base : Fields, command : String) -> Start raise {
  let home = options.home()
  make_dir(host, grok_home(home))
  if options.resume is Some(id) && grok_session_at(host, home, id) is None {
    raise FsError("no Grok Build session \{id}")
  }
  {
    command,
    args: grok_args(options.chosen_model(), options.effort),
    env: grok_env(options, base),
    files: [],
    open: None,
    meta: Some(obj([("rules", js(grok_rules(options.instructions)))])),
    opening: None,
    init_timeout: None,
  }
}

// ── Hermes Agent ─────────────────────────────────────────────────────────────────────────────────────────────────

///|
let hermes_inherited : Array[String] = [
  "PATH", "PATHEXT", "HOME", "USERPROFILE", "USER", "LOGNAME", "SHELL", "SYSTEMROOT", "WINDIR", "COMSPEC", "TEMP", "TMP", "TMPDIR", "APPDATA",
  "LOCALAPPDATA", "PROGRAMDATA", "LANG", "LANGUAGE", "TZ", "TERM", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE",
  "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "NODE_EXTRA_CA_CERTS", "SSH_AUTH_SOCK",
]

///|
pub fn hermes_home(home : String) -> String {
  join([home, "hermes"])
}

///|
pub let hermes_sessions : String = "sessions"

///|
/// `SESSION_ID`: /^[a-zA-Z0-9_-]+$/.
pub fn hermes_session_id(id : String) -> Bool {
  id != "" && all_units(id, c => is_alnum(c) || c == '_'.to_int() || c == '-'.to_int())
}

///|
/// `configuredHome`: an explicit HERMES_HOME (`~` the user's home), else `fallback`; its refusal where it is no
/// absolute path.
pub fn configured_home(value : String?, fallback : String, user_home : String) -> Result[String, String] {
  let picked = match value {
    Some(v) => trim(v)
    None => ""
  }
  if picked == "" {
    return Ok(fallback)
  }
  let path = if picked == "~" {
    user_home
  } else if picked.has_prefix("~/") || picked.has_prefix("~\\") {
    join([user_home, sub(picked, 2)])
  } else {
    picked
  }
  if !path.has_prefix("/") {
    return Err("HERMES_HOME must be an absolute path or start with ~/.")
  }
  Ok(join([path]))
}

///|
/// `newSessionHome`: the Hermes home a profile names for a new session.
pub fn hermes_new_home(options : Options, user_home : String) -> Result[String, String] {
  let env = expand_route(profile_env(options.profile, "hermes"), options.route)
  configured_home(str_of(env.get("HERMES_HOME")), hermes_home(options.home()), user_home)
}

///|
/// `sessionHome` of a resumed session's transcript's first line: the Hermes home it began in.
pub fn hermes_header_home(first_line : String, private_home : String, user_home : String) -> Result[String, String] {
  guard parse(first_line) is Some(header) else { return Err("the Hermes transcript's header is not JSON") }
  if !is_s(get(Some(header), "type"), "session") {
    return Err("Hermes transcript has no session header")
  }
  configured_home(str_of(get(Some(header), "hermesHome")), private_home, user_home)
}

///|
/// `sessionHome`: native state stays where a conversation began.
pub async fn hermes_session_home(host : @host.Host, options : Options, configured : String, user_home : String) -> String raise {
  guard options.resume is Some(id) else { return configured }
  if !hermes_session_id(id) {
    raise FsError("invalid Hermes session id")
  }
  let private_home = hermes_home(options.home())
  let path = join([private_home, hermes_sessions, "\{id}.jsonl"])
  let head = match ask_or_null(host, "fs.bytes", { "path": Json::string(path), "from": Json::number(0), "length": Json::number(16384) }) {
    String(hex) => @utf8.decode_lossy(hex_bytes(hex))
    _ => raise FsError("ENOENT: no such file or directory, open '\{path}'")
  }
  let first = match head.split("\n").next() {
    Some(l) => l.to_owned()
    None => ""
  }
  match hermes_header_home(first, private_home, user_home) {
    Ok(h) => h
    Err(why) => raise FsError(why)
  }
}

///|
fn hex_bytes(hex : String) -> Bytes {
  let out = []
  let v = (c : Int) => if c >= 'a'.to_int() { c - 'a'.to_int() + 10 } else if c >= 'A'.to_int() { c - 'A'.to_int() + 10 } else { c - '0'.to_int() }
  for i = 0; i + 1 < hex.length(); i = i + 2 {
    out.push((v(hex.unsafe_charcode_at(i)) * 16 + v(hex.unsafe_charcode_at(i + 1))).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// `hermesEnv`: the machine's execution and network settings inherited, the profile's own variables; its Hermes home
/// and the logins it may borrow kept in it; Claude Code off the keychain (`keychain_dir`: the stand-in's directory on
/// macOS, none elsewhere).
pub async fn hermes_env(host : @host.Host, options : Options, base : Fields, user_home : String, keychain_dir : String?) -> Fields raise {
  let env = Fields::new()
  for e in base.entries() {
    let key = e.0
    let upper = key.to_upper()
    let lc = upper.has_prefix("LC_") && upper.length() > 3 && all_units(sub(upper, 3), c => is_upper(c) || c == '_'.to_int())
    if e.1 is Str(_) && (hermes_inherited.contains(upper) || lc) {
      env.set(key, e.1)
    }
  }
  spread_env(env, expand_route(profile_env(options.profile, "hermes"), options.route))
  keep_local_fields(env)
  let configured = match configured_home(str_of(env.get("HERMES_HOME")), hermes_home(options.home()), user_home) {
    Ok(h) => h
    Err(why) => raise FsError(why)
  }
  let home = hermes_session_home(host, options, configured, user_home)
  env.set_str("HERMES_HOME", home)
  env.or_set("CLAUDE_CONFIG_DIR", join([home, "claude"]))
  env.or_set("CODEX_HOME", join([home, "codex"]))
  if keychain_dir is Some(dir) {
    credentials_path(env, true, dir, str_of(base.get("PATH")).unwrap_or(""))
  }
  env.set_str("STILLFAIL_PEER_HTTP", peer_http_base(options.mcp_url))
  env
}

///|
/// `HERMES_MODEL_LIMIT`.
pub let hermes_model_limit : Int = 50

///|
/// `hermesCatalog`: what its ACP inventory offers, bounded, the current model and the profile's first.
pub fn hermes_catalog(catalog : J?, profile : J) -> Array[String] {
  let valid = (v : J?) => match v {
    Some(Str(s)) => trim(t(s)) != ""
    _ => false
  }
  let found : Array[String] = []
  let add = (s : String) => if !found.contains(s) { found.push(s) }
  for m in arr(get(catalog, "availableModels")) {
    let id = get(Some(m), "modelId")
    if valid(id) {
      add(str_of(id).unwrap())
    }
  }
  let current = get(catalog, "currentModelId")
  if valid(current) {
    add(str_of(current).unwrap())
  }
  let picked : Array[String] = []
  let take = (v : J?) => if valid(v) {
    let s = str_of(v).unwrap()
    if found.contains(s) && picked.length() < hermes_model_limit && !picked.contains(s) {
      picked.push(s)
    }
  }
  take(current)
  take(get(Some(profile), "model"))
  for m in arr(get(Some(profile), "models")) {
    take(Some(m))
  }
  for m in found {
    take(Some(js(m)))
    if picked.length() == hermes_model_limit {
      break
    }
  }
  picked
}

///|
/// `HermesDriver.initialized`'s check: the adapter that reports both ends of a call (0.21.7 or newer); its refusal.
pub fn hermes_version_refusal(answer : J?) -> String? {
  let version = str_of(get(get(get(answer, "result"), "agentInfo"), "version")).unwrap_or("")
  let v = if version.has_prefix("v") { sub(version, 1) } else { version }
  let mut end = v.length()
  for c in ["-", "+"] {
    let i = index_of(v, c)
    if i >= 0 && i < end {
      end = i
    }
  }
  let parts = sub(v, 0, to=end).split(".").map(p => p.to_owned()).collect()
  let ok = parts.length() == 3 && parts.iter().all(p => p != "" && all_units(p, is_digit)) && (end == v.length() || end < v.length())
  let refusal = "Hermes Agent 需要 0.21.7 或更新版本；请先更新 Hermes，再重试。"
  if !ok {
    return Some(refusal)
  }
  let n = (s : String) => @string.parse_double(s) catch { _ => 0.0 }
  let (major, minor, patch) = (n(parts[0]), n(parts[1]), n(parts[2]))
  if major == 0.0 && (minor < 21.0 || (minor == 21.0 && patch < 7.0)) {
    Some(refusal)
  } else {
    None
  }
}

///|
/// `HermesDriver.starting`.
pub async fn hermes_start(
  host : @host.Host,
  options : Options,
  base : Fields,
  command : String,
  user_home : String,
  keychain_dir : String?,
) -> Start raise {
  if options.resume is Some(id) && !hermes_session_id(id) {
    raise FsError("invalid Hermes session id")
  }
  let sessions = join([hermes_home(options.home()), hermes_sessions])
  make_dir(host, sessions)
  if options.resume is Some(id) && !exists(host, join([sessions, "\{id}.jsonl"])) {
    raise FsError("no Hermes session \{id}")
  }
  {
    command,
    args: ["acp"],
    env: hermes_env(host, options, base, user_home, keychain_dir),
    files: [],
    open: None,
    meta: None,
    opening: None,
    init_timeout: Some(600000.0),
  }
}

///|
/// `HermesDriver.models`' session: one opened only to ask what the profile's Hermes offers (a probe: no tools, no
/// instructions, nothing kept), `uuid` its key's.
pub fn hermes_models_options(profile : J, uuid : String) -> Options {
  let id = said(get(Some(profile), "id"))
  {
    key: "models-\{id}-\{uuid}",
    profile,
    cwd: home_of(profile),
    resume: None,
    model: None,
    effort: None,
    instructions: "",
    skills: None,
    mcp_token: "",
    mcp_url: "",
    route: "model-discovery",
  }
}

///|
/// Whether `HermesDriver.models` asks again after `message`: only the refusal of a fresh HERMES_HOME while another
/// launch holds the shared checkout's update lock, until its deadline (120 s from the first ask) or the driver stops.
pub fn hermes_models_again(message : String, now : Double, deadline : Double, stopping : Bool) -> Bool {
  message.contains("an update is still running") &&
  message.contains("no dependency environment is committed") &&
  now < deadline &&
  !stopping
}

///|
/// acp.ts `AcpDriver.hosting`, own-process.ts `Hosting`: how the program reads a runtime's processes (an ACP runtime's
/// flavor, and whether the station keeps its transcript).
pub fn hosting_of(runtime : String) -> J {
  match runtime {
    "dsh" | "cursor" | "pi" => obj([("kind", js(runtime))])
    _ => obj([("kind", js("acp")), ("flavor", js(runtime)), ("kept", Bool(runtime == "devin" || runtime == "hermes"))])
  }
}
