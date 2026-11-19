// What the accounts read of a model's name and of a profile's account, as the TypeScript they come from has it:
// client/core-ts/src/shapes/model.ts (`key`, `splitAgyTier`, `splitDevinFusion`), station/src/agents/agy.ts
// (`agyBaseModel`), station/src/agents/devin.ts (`splitDevinFusion`, `devinFusionBase`, `expandDevinFusion`),
// station/src/agents/runtime.ts (the runtimes and their names), station/src/agents/providers.ts (the API providers and
// where each speaks), station/src/agents/profiles.ts (a profile's access) and station/src/accounts/profiles.ts (what
// each runtime takes).

///|
fn is_digits(s : String) -> Bool {
  s.length() > 0 && s.iter().all(c => c >= '0' && c <= '9')
}

///|
fn is_alpha(s : String) -> Bool {
  s.length() > 0 && s.iter().all(c => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
}

///|
/// `s.slice(a, b)` with JavaScript's clamping (code units).
fn slice(s : String, a : Int, b? : Int) -> String {
  @jsjson.js_slice(s, a, end?=b)
}

///|
/// `s.indexOf(t, from)`.
fn index_of(s : String, t : String, from? : Int = 0) -> Int {
  @jsjson.js_index_of(s, t, from~)
}

///|
/// `s.lastIndexOf(t)`.
fn last_index_of(s : String, t : String) -> Int {
  @jsjson.js_last_index_of(s, t)
}

///|
/// `s.split(sep)` (a non-empty separator).
fn split_on(s : String, sep : String) -> Array[String] {
  let out = []
  let mut from = 0
  while true {
    let at = index_of(s, sep, from~)
    if at < 0 {
      out.push(slice(s, from))
      break
    }
    out.push(slice(s, from, b=at))
    from = at + sep.length()
  }
  out
}

///|
/// `s.toLowerCase()`.
fn lower(s : String) -> String {
  s.to_lower()
}

///|
fn stamp(s : String) -> Bool {
  let colon = index_of(s, ":")
  if colon < 0 {
    return false
  }
  is_digits(slice(s, 0, b=colon)) && is_digits(slice(s, colon + 1))
}

///|
let devin_levels_core : Array[String] = ["low", "medium", "high", "xhigh", "max"]

///|
/// The model.ts `splitDevinFusion`'s normalized model (`fusion-<lead>-sidekick-<side>`), as `key` uses it.
fn core_devin_fusion_model(id : String) -> String? {
  let trimmed = trim_js(id)
  if !trimmed.has_prefix("fusion-") {
    return None
  }
  let mark = "-sidekick-"
  let at = index_of(trimmed, mark, from=7)
  if at <= 7 || at + mark.length() >= trimmed.length() {
    return None
  }
  let raw_lead = slice(trimmed, 7, b=at)
  let side = slice(trimmed, at + mark.length())
  let effort = devin_levels_core.iter().find_first(l => raw_lead.has_suffix("-\{l}") && raw_lead.length() > l.length() + 1)
  let lead = match effort {
    None => raw_lead
    Some(e) => slice(raw_lead, 0, b=raw_lead.length() - e.length() - 1)
  }
  Some("fusion-\{lead}-sidekick-\{side}")
}

///|
/// What a model is, however it is spelled: lower case, without its provider's prefix, region, version stamp or date
/// (model.ts `key`, read/usage.ts `modelKey`).
pub fn model_key(id : String) -> String {
  let lowered = lower(trim_js(id))
  let at = index_of(lowered, "[")
  let (base, context) = if at >= 0 {
    (slice(lowered, 0, b=at), slice(lowered, at))
  } else {
    (lowered, "")
  }
  let parts_slash = split_on(base, "/")
  let mut m = parts_slash[parts_slash.length() - 1]
  m = split_on(m, "@")[0]
  while true {
    let dot = index_of(m, ".")
    if dot < 0 {
      break
    }
    let head = slice(m, 0, b=dot)
    let rest = slice(m, dot + 1)
    if !is_alpha(head) || rest == "" {
      break
    }
    m = rest
  }
  m = claude_dashed(m)
  let v = last_index_of(m, "-v")
  if v >= 0 && stamp(slice(m, v + 2)) {
    m = slice(m, 0, b=v)
  }
  let parts = split_on(m, "-")
  let n = parts.length()
  let digits = (s : String, k : Int) => s.length() == k && is_digits(s)
  if n > 1 && digits(parts[n - 1], 8) {
    m = parts[0:n - 1].to_array().join("-")
  } else if n > 3 &&
    digits(parts[n - 3], 4) &&
    digits(parts[n - 2], 2) &&
    digits(parts[n - 1], 2) {
    m = parts[0:n - 3].to_array().join("-")
  }
  if m.has_prefix("fusion-") && m.contains("-sidekick-") {
    match core_devin_fusion_model(m) {
      Some(x) => m = x
      None => ()
    }
  }
  m + context
}

///|
/// Two spellings of one model (config.ts `sameModel`).
pub fn same_model(a : String, b : String) -> Bool {
  a == b || model_key(a) == model_key(b)
}

///|
let agy_levels : Array[String] = [
  "none", "minimal", "low", "medium", "high", "xhigh", "max",
]

///|
/// An Antigravity tiered id split into its model and level (model.ts `splitAgyTier`).
pub fn split_agy_tier(id : String) -> (String, String)? {
  let trimmed = trim_js(id)
  match agy_levels.iter().find_first(l => trimmed.has_suffix("-\{l}") && trimmed.length() > l.length() + 1) {
    None => None
    Some(e) => Some((slice(trimmed, 0, b=trimmed.length() - e.length() - 1), e))
  }
}

///|
/// agy.ts `agyBaseModel`: the model without its level.
pub fn agy_base_model(id : String) -> String {
  match split_agy_tier(id) {
    Some((m, _)) => m
    None => trim_js(id)
  }
}

///|
/// agents/devin.ts `splitDevinFusion`: lead, its level, side.
pub fn devin_fusion_split(id : String) -> (String, String?, String)? {
  let s = lower(trim_js(id))
  if !s.has_prefix("fusion-") {
    return None
  }
  let at = index_of(s, "-sidekick-", from=7)
  if at < 0 {
    return None
  }
  let raw_lead = slice(s, 7, b=at)
  let side = slice(s, at + 10)
  if raw_lead == "" || side == "" {
    return None
  }
  let effort = agy_levels.iter().find_first(l => raw_lead.has_suffix("-\{l}") && raw_lead.length() > l.length() + 1)
  let lead = match effort {
    Some(e) => slice(raw_lead, 0, b=raw_lead.length() - e.length() - 1)
    None => raw_lead
  }
  Some((lead, effort, side))
}

///|
/// agents/devin.ts `devinFusionBase`'s model.
pub fn devin_fusion_base(id : String) -> String {
  match devin_fusion_split(id) {
    Some((lead, _, side)) => "fusion-\{lead}-sidekick-\{side}"
    None => id
  }
}

///|
/// agents/devin.ts `expandDevinFusion`: a Devin Fusion catalog's pairs as models.
pub fn expand_devin_fusion(fusion : JV?) -> Array[String] {
  let out : Array[String] = []
  match fusion {
    Some(Obj(_) as f) => {
      let sides = jitems(f.get("sides"))
      for p in jfields(f.get("leads")) {
        let raw_lead = p.0
        let lead = match devin_fusion_split("fusion-\{raw_lead}-sidekick-x") {
          Some((l, _, _)) => l
          None => raw_lead
        }
        for i in jitems(Some(p.1)) {
          let side = match i {
            Num(n) if is_integer(n) && n >= 0.0 && n < sides.length().to_double() =>
              jstr(Some(sides[n.to_int()]))
            _ => None
          }
          match side {
            Some(s) if s != "" => {
              let m = "fusion-\{lead}-sidekick-\{s}"
              if !out.contains(m) {
                out.push(m)
              }
            }
            _ => ()
          }
        }
      }
    }
    _ => ()
  }
  out
}

// ── the runtimes (agents/runtime.ts) ──

///|
pub let runtime_kinds : Array[String] = [
  "claude", "codex", "dsh", "grok", "cursor", "devin", "hermes", "agy", "pi",
]

///|
/// `runtimeKind`: a runtime's name, none for anything else.
pub fn runtime_kind(v : JV?) -> String? {
  match v {
    Some(Str(s)) if runtime_kinds.contains(s) => Some(s)
    _ => None
  }
}

///|
/// `runtimeLabel`: how a runtime is named to people.
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

// ── the API providers (agents/providers.ts) ──

///|
pub(all) struct Source {
  id : String
  name : String
  chat : String?
  responses : String?
  anthropic : String?
  decision : String?
  endpoint_required : Bool
  protocols : Array[String]
  key_optional : Bool
  auth : String
  session_header : Bool
}

///|
fn source(
  id : String,
  name : String,
  chat? : String,
  responses? : String,
  anthropic? : String,
  decision? : String,
  endpoint_required? : Bool = false,
  protocols? : Array[String] = [],
  key_optional? : Bool = false,
  auth? : String = "bearer",
  session_header? : Bool = false,
) -> Source {
  {
    id,
    name,
    chat,
    responses,
    anthropic,
    decision,
    endpoint_required,
    protocols,
    key_optional,
    auth,
    session_header,
  }
}

///|
let all_protocols : Array[String] = ["chat_completions", "responses", "anthropic"]

///|
/// In the order they are offered.
pub let sources : Array[Source] = [
  source("openai", "OpenAI", responses="https://api.openai.com/v1"),
  source("anthropic", "Anthropic", anthropic="https://api.anthropic.com", auth="apiKey"),
  source("google", "Google Gemini", chat="https://generativelanguage.googleapis.com/v1beta/openai"),
  source("xai", "xAI", responses="https://api.x.ai/v1"),
  source("mistral", "Mistral", chat="https://api.mistral.ai/v1"),
  source("deepseek", "DeepSeek", chat="https://api.deepseek.com"),
  source("qwen", "Qwen", chat="https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"),
  source("moonshotai", "Kimi", chat="https://api.moonshot.ai/v1"),
  source("kimi-code", "Kimi Code", anthropic="https://api.kimi.com/coding", chat="https://api.kimi.com/coding/v1"),
  source("zai", "Z.ai", chat="https://api.z.ai/api/coding/paas/v4"),
  source("minimax", "MiniMax", anthropic="https://api.minimax.io/anthropic"),
  source("xiaomi", "Xiaomi MiMo", chat="https://api.xiaomimimo.com/v1"),
  source("ant-ling", "Ant Ling", chat="https://api.ant-ling.com/v1"),
  source("jev", "Jev", decision="https://api.typesafe.ai/v1"),
  source("qwen-cn", "Qwen (China)", chat="https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"),
  source("moonshotai-cn", "Kimi (China)", chat="https://api.moonshot.cn/v1"),
  source("zai-coding-cn", "Z.ai Coding (China)", chat="https://open.bigmodel.cn/api/coding/paas/v4"),
  source("minimax-cn", "MiniMax (China)", anthropic="https://api.minimaxi.com/anthropic"),
  source("openrouter", "OpenRouter", anthropic="https://openrouter.ai/api", chat="https://openrouter.ai/api/v1"),
  source("vercel-ai-gateway", "Vercel AI Gateway", anthropic="https://ai-gateway.vercel.sh"),
  source(
    "opencode",
    "OpenCode Zen",
    anthropic="https://opencode.ai/zen",
    chat="https://opencode.ai/zen/v1",
    responses="https://opencode.ai/zen/v1",
    auth="apiKey",
    session_header=true,
  ),
  source(
    "opencode-go",
    "OpenCode Go",
    anthropic="https://opencode.ai/zen/go",
    chat="https://opencode.ai/zen/go/v1",
    responses="https://opencode.ai/zen/go/v1",
    auth="apiKey",
    session_header=true,
  ),
  source("cloudflare-ai-gateway", "Cloudflare AI Gateway", endpoint_required=true, protocols=all_protocols, auth="both"),
  source("azure-openai", "Azure OpenAI", endpoint_required=true, protocols=["responses"]),
  source("groq", "Groq", chat="https://api.groq.com/openai/v1"),
  source("together", "Together AI", chat="https://api.together.ai/v1"),
  source("fireworks", "Fireworks", anthropic="https://api.fireworks.ai/inference", chat="https://api.fireworks.ai/inference/v1"),
  source("cerebras", "Cerebras", chat="https://api.cerebras.ai/v1"),
  source("huggingface", "Hugging Face", chat="https://router.huggingface.co/v1"),
  source("nvidia", "NVIDIA", chat="https://integrate.api.nvidia.com/v1"),
  source("baseten", "Baseten", chat="https://inference.baseten.co/v1"),
  source("cloudflare-workers-ai", "Cloudflare Workers AI", endpoint_required=true, protocols=["chat_completions"]),
  source("ollama", "Ollama", endpoint_required=true, protocols=["chat_completions"], key_optional=true),
  source("custom", "Custom", endpoint_required=true, protocols=all_protocols, key_optional=true, auth="both"),
]

///|
pub fn find_source(id : String) -> Source? {
  sources.iter().find_first(s => s.id == id)
}

///|
/// The two made before the list (`LEGACY`): not offered again as a provider.
pub fn legacy_source(id : String) -> Bool {
  id == "anthropic" || id == "opencode-go"
}

///|
/// `groupOf`: how the picker groups them.
pub fn group_of(id : String) -> String {
  if ["openrouter", "vercel-ai-gateway", "opencode", "opencode-go", "cloudflare-ai-gateway"].contains(id) {
    "gateways"
  } else if [
      "azure-openai", "groq", "together", "fireworks", "cerebras", "huggingface",
      "nvidia", "baseten", "cloudflare-workers-ai",
    ].contains(id) {
    "hosted"
  } else if id == "ollama" || id == "custom" {
    "local"
  } else {
    "labs"
  }
}

///|
fn js_space(c : Int) -> Bool {
  @jsjson.is_js_space(c)
}

///|
/// `/\s/.test(s)`.
fn has_space(s : String) -> Bool {
  for i in 0..<s.length() {
    if js_space(s.unsafe_charcode_at(i)) {
      return true
    }
  }
  false
}

///|
/// `cleanEndpoint`: trimmed, without a trailing slash; none unless it is an http(s) address.
pub fn clean_endpoint(text : String) -> String? {
  let mut trimmed = trim_js(text)
  while trimmed.has_suffix("/") {
    trimmed = slice(trimmed, 0, b=trimmed.length() - 1)
  }
  let rest = if trimmed.has_prefix("https://") {
    Some(slice(trimmed, 8))
  } else if trimmed.has_prefix("http://") {
    Some(slice(trimmed, 7))
  } else {
    None
  }
  match rest {
    Some(r) if r != "" && !has_space(r) => Some(trimmed)
    _ => None
  }
}

///|
fn anthropic_root(base : String) -> String {
  if base.has_suffix("/v1") {
    slice(base, 0, b=base.length() - 3)
  } else {
    base
  }
}

///|
pub(all) struct Endpoints {
  chat : String?
  responses : String?
  anthropic : String?
  decision : String?
}

///|
/// `endpoints`: where a source speaks; for one at the person's own address, of it and the protocol chosen.
pub fn endpoints(
  s : Source,
  endpoint : String?,
  protocol : String?,
) -> Endpoints? {
  if !s.endpoint_required {
    return Some({
      chat: s.chat,
      responses: s.responses,
      anthropic: s.anthropic,
      decision: s.decision,
    })
  }
  let base = match endpoint {
    None => None
    Some(e) => clean_endpoint(e)
  }
  guard base is Some(base) else { return None }
  let chosen = match protocol {
    Some(p) if all_protocols.contains(p) => Some(p)
    _ => None
  }
  if chosen is Some(c) && !s.protocols.contains(c) {
    return None
  }
  let none : String? = None
  if s.id == "cloudflare-ai-gateway" {
    let suffix = ["/compat", "/openai", "/anthropic"].iter().find_first(x => base.has_suffix(x))
    let root = match suffix {
      Some(x) => slice(base, 0, b=base.length() - x.length())
      None => base
    }
    let mut chat = Some("\{root}/compat")
    let mut responses = Some("\{root}/openai")
    let mut anthropic = Some("\{root}/anthropic")
    if chosen is Some(c) {
      if c != "chat_completions" {
        chat = None
      }
      if c != "responses" {
        responses = None
      }
      if c != "anthropic" {
        anthropic = None
      }
    }
    Some({ chat, responses, anthropic, decision: none })
  } else if s.id == "azure-openai" {
    Some({ chat: none, responses: Some(base), anthropic: none, decision: none })
  } else if s.id == "cloudflare-workers-ai" || s.id == "ollama" {
    Some({ chat: Some(base), responses: none, anthropic: none, decision: none })
  } else if chosen == Some("chat_completions") {
    Some({ chat: Some(base), responses: none, anthropic: none, decision: none })
  } else if chosen == Some("responses") {
    Some({ chat: none, responses: Some(base), anthropic: none, decision: none })
  } else if chosen == Some("anthropic") {
    Some({ chat: none, responses: none, anthropic: Some(anthropic_root(base)), decision: none })
  } else {
    Some({
      anthropic: if base.has_suffix("/v1") { Some(anthropic_root(base)) } else { None },
      chat: Some(base),
      responses: Some(base),
      decision: none,
    })
  }
}

///|
/// `runtimesOf` (providers.ts): the runtimes a provider's profile can run, from where it speaks.
pub fn runtimes_of_endpoints(at : Endpoints) -> Array[String] {
  let out = []
  if at.anthropic is Some(_) {
    out.push("claude")
  }
  if at.responses is Some(_) {
    out.push("codex")
  }
  if at.chat is Some(_) || at.anthropic is Some(_) || at.responses is Some(_) {
    out.push("dsh")
    out.push("pi")
  }
  out
}

// ── a profile's access (agents/profiles.ts) ──

///|
pub let kimi_code : String = "kimi-code"

///|
fn access_of(p : JV) -> JV {
  match p.get("access") {
    Some(Obj(_) as a) => a
    Some(Arr(_) as a) => a
    _ => Obj([])
  }
}

///|
fn nonempty_str(v : JV?) -> String? {
  match v {
    Some(Str(s)) if s != "" => Some(s)
    _ => None
  }
}

///|
/// `accessKind`: the profile's access kind ("env" where it says none).
pub fn access_kind(p : JV) -> String {
  match access_of(p).get("kind") {
    Some(Null) | None => "env"
    Some(Str(s)) => s
    Some(other) => js_string(Some(other))
  }
}

///|
/// The access kinds there are, in config.json's words.
let access_kinds_all : Array[String] = [
  "subscription", "opencode-go", "anthropic-api", "env", "api-provider",
]

///|
/// `accessKindOf`: the kind it names, none for anything else.
pub fn access_kind_of(v : JV?) -> String? {
  match v {
    Some(Str(s)) if access_kinds_all.contains(s) => Some(s)
    _ => None
  }
}

///|
/// `billedPerUse`: an account billed for what it uses.
pub fn billed_per_use(p : JV) -> Bool {
  let kind = access_kind(p)
  kind == "anthropic-api" ||
  kind == "env" ||
  (kind == "api-provider" && access_of(p).get("provider") != Some(Str(kimi_code)))
}

///|
/// `kimiSignedIn`: a Kimi Code profile signed in to the person's Kimi account.
pub fn kimi_signed_in(p : JV) -> Bool {
  let a = access_of(p)
  access_kind(p) == "api-provider" &&
  a.get("provider") == Some(Str(kimi_code)) &&
  a.get("login") == Some(Bool(true))
}

///|
pub let fast_runtimes : Array[String] = ["codex", "claude"]

///|
/// `takesFast`.
pub fn takes_fast(p : JV) -> Bool {
  let kind = access_kind(p)
  let runtime = p.get("runtime")
  if runtime == Some(Str("codex")) {
    return kind == "subscription"
  }
  if runtime != Some(Str("claude")) {
    return false
  }
  kind == "anthropic-api" ||
  kind == "subscription" ||
  (kind == "api-provider" && access_of(p).get("provider") == Some(Str("openrouter")))
}

///|
/// `fastNeedsCredits`: a Claude subscription.
pub fn fast_needs_credits(p : JV) -> Bool {
  p.get("runtime") == Some(Str("claude")) && access_kind(p) == "subscription"
}

///|
pub(all) struct Via {
  provider : String?
  endpoint : String?
  protocol : String?
}

///|
/// `profileVia`.
pub fn profile_via(p : JV) -> Via {
  let a = access_of(p)
  {
    provider: nonempty_str(a.get("provider")),
    endpoint: match a.get("endpoint") {
      None => None
      Some(Str(e)) => clean_endpoint(e)
      Some(other) => clean_endpoint(js_string(Some(other)))
    },
    protocol: nonempty_str(a.get("protocol")),
  }
}

///|
/// `apiSource`: the source of an API-provider profile and where it speaks.
pub fn api_source(via : Via) -> (Source, Endpoints)? {
  guard via.provider is Some(id) else { return None }
  guard find_source(id) is Some(s) else { return None }
  match endpoints(s, via.endpoint, via.protocol) {
    Some(at) => Some((s, at))
    None => None
  }
}

///|
/// `profileRuntimes`: the runtimes an account runs.
pub fn profile_runtimes(p : JV) -> Array[String] {
  let kind = access_kind(p)
  if kind == "api-provider" {
    guard api_source(profile_via(p)) is Some((s, at)) else { return [] }
    if kimi_signed_in(p) {
      return ["claude"]
    }
    let base = runtimes_of_endpoints(at)
    if s.id == "xai" {
      base.push("grok")
    } else if s.id == "google" {
      base.push("agy")
    }
    return base
  }
  if kind == "opencode-go" {
    return ["claude", "codex", "dsh", "pi"]
  }
  if kind == "anthropic-api" {
    return ["claude", "dsh", "pi"]
  }
  let own = runtime_kind(p.get("runtime"))
  if (own == Some("dsh") || own == Some("pi")) && kind == "subscription" {
    return []
  }
  match own {
    Some(r) => [r]
    None => []
  }
}

// ── what each runtime takes (accounts/profiles.ts) ──

///|
/// `accessKinds`: the access kinds a runtime can use.
pub fn access_kinds(runtime : String) -> Array[String] {
  match runtime {
    "hermes" => ["env"]
    "agy" => ["subscription", "api-provider", "env"]
    "claude" =>
      ["subscription", "opencode-go", "anthropic-api", "api-provider", "env"]
    "dsh" | "pi" => ["opencode-go", "anthropic-api", "api-provider", "env"]
    "grok" => ["subscription", "api-provider", "env"]
    "cursor" | "devin" => ["subscription", "env"]
    _ => ["subscription", "opencode-go", "api-provider", "env"]
  }
}

///|
/// `keyed`: an access that runs on a key.
pub fn keyed(kind : String) -> Bool {
  kind == "opencode-go" || kind == "anthropic-api" || kind == "api-provider"
}

///|
/// `needsKey`.
pub fn needs_key(kind : String, provider : String?) -> Bool {
  keyed(kind) &&
  !(
    kind == "api-provider" &&
    (match provider {
      Some(id) =>
        match find_source(id) {
          Some(s) => s.key_optional
          None => false
        }
      None => false
    })
  )
}

///|
/// `runtimesOf` (accounts/profiles.ts): the runtimes an access kind runs without its provider.
pub fn runtimes_of_kind(kind : String, runtime : String?) -> Array[String] {
  if kind == "opencode-go" {
    return ["claude", "codex", "dsh", "pi"]
  }
  if kind == "anthropic-api" {
    return ["claude", "dsh", "pi"]
  }
  if kind == "api-provider" {
    return []
  }
  if kind == "subscription" && (runtime == Some("dsh") || runtime == Some("pi")) {
    return []
  }
  match runtime {
    Some(r) => [r]
    None => []
  }
}

///|
/// `runtimesFor`: the runtimes of an access as config.json has it.
pub fn runtimes_for(access : JV?, runtime : JV?) -> Array[String] {
  let fields = [("id", js("")), ("home", js(""))]
  if runtime is Some(r) {
    fields.push(("runtime", r))
  }
  if access is Some(a) {
    fields.push(("access", a))
  }
  profile_runtimes(Obj(fields))
}

///|
/// `maskValue` (ops/agent-env.ts): a secret as the pages show it.
pub fn mask(value : String) -> String {
  if value == "" {
    return ""
  }
  let cs = points(value)
  if cs.length() <= 8 {
    return "••••"
  }
  cs[0:5].to_array().join("") + "…" + cs[cs.length() - 4:].to_array().join("")
}

///|
/// `secretKey`: a variable that holds a secret.
pub fn secret_key(key : String) -> Bool {
  let up = key.to_upper()
  ["KEY", "TOKEN", "SECRET", "PASSWORD", "AUTH"].iter().any(w => up.contains(w))
}

///|
/// model.ts `key`: Claude's version said with a dot (OpenRouter's claude-opus-5.5) is Anthropic's claude-opus-5-5.
fn claude_dashed(m : String) -> String {
  if !m.has_prefix("claude-") {
    return m
  }
  let cs = m.iter().collect()
  let n = cs.length()
  let digit = (j : Int) => j >= 0 && j < n && cs[j] >= '0' && cs[j] <= '9'
  let buf = StringBuilder::new()
  for i in 0..<n {
    buf.write_char(if cs[i] == '.' && digit(i - 1) && digit(i + 1) { '-' } else { cs[i] })
  }
  buf.to_string()
}

///|
test "a Claude version said with a dot is the dashed one" {
  assert_eq(model_key("anthropic/claude-opus-5.5"), "claude-opus-5-5")
  assert_eq(model_key("claude-opus-5-5"), "claude-opus-5-5")
  assert_eq(model_key("gpt-5.1"), "gpt-5.1")
}
