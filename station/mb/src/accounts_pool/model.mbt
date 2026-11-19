// What the accounts read of a model's name and of a profile's account, delegated to @readops and @agent_runtimes.

///|
pub using @readops {model_key}

///|
pub using @agent_runtimes {
  type Source,
  type Endpoints,
  type Via,
  find as find_source,
  group_of,
  clean_endpoint,
  endpoints,
  runtimes_of as runtimes_of_endpoints,
  runtime_kind,
  runtime_label,
  split_agy_tier,
  expand_devin_fusion,
  access_kind,
  billed_per_use,
  kimi_signed_in,
  takes_fast,
  fast_needs_credits,
  profile_via,
  api_source,
  profile_runtimes,
  access_kinds,
  keyed,
  runtimes_of_kind,
}

///|
using @jsjson {
  js_index_of as index_of,
  is_js_space as js_space,
  js_all_digits as is_digits,
  js_split as split_on,
  jval_nonempty as nonempty_str,
}

///|
pub let runtime_kinds : Array[String] = @agent_runtimes.runtime_kinds

///|
pub let sources : Array[Source] = @agent_runtimes.sources

///|
pub let kimi_code : String = @agent_runtimes.kimi_code

///|
pub let fast_runtimes : Array[String] = @agent_runtimes.fast_runtimes

///|
let agy_levels : Array[String] = @agent_runtimes.agy_levels

///|
/// `s.slice(a, b)` with JavaScript's clamping (code units).
fn slice(s : String, a : Int, b? : Int) -> String {
  @jsjson.js_slice(s, a, end?=b)
}

///|
/// `s.toLowerCase()`.
fn lower(s : String) -> String {
  s.to_lower()
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
/// Two spellings of one model (config.ts `sameModel`).
pub fn same_model(a : String, b : String) -> Bool {
  a == b || model_key(a) == model_key(b)
}

///|
/// agy.ts `agyBaseModel`: the model without its level.
pub fn agy_base_model(id : String) -> String {
  @agent_runtimes.agy_base_model(id).0
}

///|
/// agents/devin.ts `splitDevinFusion`: lead, its level, side.
pub fn devin_fusion_split(id : String) -> (String, String?, String)? {
  @agent_runtimes.split_devin_fusion(id).map(f => (f.lead, f.effort, f.side))
}

///|
/// agents/devin.ts `devinFusionBase`'s model.
pub fn devin_fusion_base(id : String) -> String {
  @agent_runtimes.devin_fusion_base(id).0
}

///|
/// The two made before the list (`LEGACY`): not offered again as a provider.
pub fn legacy_source(id : String) -> Bool {
  @agent_runtimes.legacy(id) is Some(_)
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
test "a Claude version said with a dot is the dashed one" {
  assert_eq(model_key("anthropic/claude-opus-5.5"), "claude-opus-5-5")
  assert_eq(model_key("claude-opus-5-5"), "claude-opus-5-5")
  assert_eq(model_key("gpt-5.1"), "gpt-5.1")
}
