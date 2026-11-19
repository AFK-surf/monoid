// What the hub and the pool read of a profile and a model (station/src/sessions/config.ts `spelling`, `runs`,
// `sameModel`, `allowedIn`; agents/runtime.ts, agents/profiles.ts, agents/agy.ts, agents/devin.ts; ops/model-name.ts;
// client/core-ts/src/model-speed.ts): a profile is config.json's, as JSON.

///|
/// agents/runtime.ts `RUNTIME_KINDS`.
pub let runtime_kinds : Array[String] = @agent_runtimes.runtime_kinds

///|
/// `runtimeKind` (config.ts `runtimeNamed`): a runtime as stored or sent, none for anything else.
pub fn runtime_named(name : String) -> String? {
  if runtime_kinds.contains(name) {
    Some(name)
  } else {
    None
  }
}

///|
/// `runtimeLabel` and `agyBaseModel`, delegated to `@agent_runtimes`.
pub using @agent_runtimes {runtime_label, agy_base_model}

///|
/// shapes model.rs `same`: two spellings are one model.
pub fn same_model(a : String, b : String) -> Bool {
  a == b || @readops.model_key(a) == @readops.model_key(b)
}

///|
/// devin.ts `splitDevinFusion`: a Fusion pair's lead, its level and its sidekick.
pub fn split_devin_fusion(id : String) -> (String, String?, String)? {
  @agent_runtimes.split_devin_fusion(id).map(f => (f.lead, f.effort, f.side))
}

///|
/// devin.ts `devinFusionBase`: a Fusion pair without its lead's level.
pub fn devin_fusion_base(id : String) -> String {
  @agent_runtimes.devin_fusion_base(id).0
}

///|
/// A profile's models (`models`), as strings.
pub fn profile_models(p : Json) -> Array[String] {
  items(field(p, "models")).filter_map(m => match m { String(s) => Some(s); _ => None })
}

///|
/// A profile's runtimes (`runtimes`).
pub fn profile_runtimes(p : Json) -> Array[String] {
  items(field(p, "runtimes")).filter_map(m => match m { String(s) => Some(s); _ => None })
}

///|
/// A profile's id.
pub fn profile_id(p : Json) -> String {
  str_of(p, "id").unwrap_or("")
}

///|
/// config.ts `spelling`: its own spelling of a model it runs, however the model is spelled.
pub fn spelling(profile : Json, model : String) -> String? {
  let models = profile_models(profile)
  match models.iter().find_first(m => m == model) {
    Some(m) => return Some(m)
    None => ()
  }
  match models.iter().find_first(m => same_model(m, model)) {
    Some(m) => return Some(m)
    None => ()
  }
  let runtimes = profile_runtimes(profile)
  if runtimes.contains("agy") {
    let base = agy_base_model(model).0
    return models
      .iter()
      .find_first(m => m == base || same_model(m, base) || agy_base_model(m).0 == base)
  }
  if runtimes.contains("devin") {
    match split_devin_fusion(model) {
      Some((lead, _, side)) => {
        let base = "fusion-\{lead}-sidekick-\{side}"
        if models.iter().any(m => m == base || same_model(m, base) || devin_fusion_base(m) == base) {
          return Some(base)
        }
        if models.iter().any(m => m == lead || same_model(m, lead)) {
          return Some(base)
        }
      }
      None => ()
    }
  }
  None
}

///|
/// config.ts `runs`: whether it runs a model, in any spelling.
pub fn runs(profile : Json, model : String) -> Bool {
  spelling(profile, model) is Some(_)
}

///|
/// pool.ts `serves`: a chosen model needs the profile to run it; no model means the profile's own default.
pub fn serves(profile : Json, model : String?) -> Bool {
  match model {
    None => true
    Some(m) => runs(profile, m)
  }
}

///|
/// config.ts `allowedIn`: whether sessions of workspace `ws` (None: the home one's) may run on a profile.
pub fn allowed_in(profile : Json, ws : String?, home : String?) -> Bool {
  let share = field(profile, "share")
  let only = match share {
    Some(Object(_) as s) if is_true(s, "borrowed") =>
      match field(s, "workspaces") {
        Some(Array(list)) => Some(list)
        _ => None
      }
    _ => None
  }
  let at = match ws {
    Some(_) => ws
    None => home
  }
  match (only, at) {
    (Some(list), Some(a)) => if !list.contains(Json::string(a)) { return false }
    _ => ()
  }
  match (ws, home) {
    (None, _) | (_, None) => true
    (Some(w), Some(h)) =>
      w == h || !items(field(profile, "withheld")).contains(Json::string(w))
  }
}

///|
/// Whether a profile is enabled (`enabled !== false`).
pub fn enabled(profile : Json) -> Bool {
  !(field(profile, "enabled") is Some(False))
}

///|
/// profiles.ts `accessKind`.
pub fn access_kind(p : Json) -> String {
  @agent_runtimes.access_kind(@jsjson.JValue::of_json(p))
}

///|
/// profiles.ts `billedPerUse`: an Anthropic key, a provider's key (but Kimi Code's membership), or a runtime's own
/// variables.
pub fn billed_per_use(p : Json) -> Bool {
  @agent_runtimes.billed_per_use(@jsjson.JValue::of_json(p))
}

///|
/// profiles.ts `FAST_RUNTIMES`.
pub let fast_runtimes : Array[String] = @agent_runtimes.fast_runtimes

///|
/// model-speed.ts `modelSpeed`.
pub fn model_speed(v : Json?) -> String? {
  match v {
    Some(String("standard" | "fast" | "ultrafast" as s)) => Some(s)
    _ => None
  }
}

///|
/// model-speed.ts `chosenSpeed` of an object with `speed` and `fast`.
pub fn chosen_speed(v : Json) -> String? {
  match model_speed(field(v, "speed")) {
    Some(s) => Some(s)
    None =>
      match field(v, "fast") {
        Some(True) => Some("fast")
        Some(False) => Some("standard")
        _ => None
      }
  }
}

///|
/// model-speed.ts `ultrafastModel`.
pub fn ultrafast_model(model : Json?, reported : Json?) -> Bool {
  match model {
    Some(String(m)) => {
      let k = @readops.model_key(m)
      match reported {
        Some(Array(models)) => models.iter().any(id => match id {
          String(id) => @readops.model_key(id) == k
          _ => false
        })
        _ => k == "gpt-6-astra" || k == "gpt-6.1-sol"
      }
    }
    _ => false
  }
}

// ── model-name.ts ──

///|
let claude_families : Array[String] = ["fable", "opus", "sonnet", "haiku"]

///|
fn brand(w : String) -> String? {
  match w {
    "deepseek" => Some("DeepSeek")
    "minimax" => Some("MiniMax")
    "qwq" => Some("QwQ")
    "glm" => Some("GLM")
    "gpt" => Some("GPT")
    "swe" => Some("SWE")
    "oss" => Some("OSS")
    "moonshot" => Some("Moonshot")
    "devstral" => Some("Devstral")
    "codestral" => Some("Codestral")
    "llama" => Some("Llama")
    "ernie" => Some("ERNIE")
    "vl" => Some("VL")
    "r1" => Some("R1")
    "it" => Some("IT")
    _ => None
  }
}

///|
fn is_digit_unit(c : Int) -> Bool {
  c >= '0'.to_int() && c <= '9'.to_int()
}

///|
fn digits_only(w : String) -> Bool {
  w.length() > 0 && w.iter().all(c => is_digit_unit(c.to_int()))
}

///|
/// /^[0-9]+(\.[0-9]+)?[bmk]$/
fn size_word(w : String) -> Bool {
  let n = w.length()
  if n < 2 {
    return false
  }
  let last = u(w, n - 1)
  if last != 'b'.to_int() && last != 'm'.to_int() && last != 'k'.to_int() {
    return false
  }
  let body = slice(w, 0, to=n - 1)
  let parts = split(body, ".")
  match parts {
    [a] => digits_only(a)
    [a, b] => digits_only(a) && digits_only(b)
    _ => false
  }
}

///|
fn upper_ascii(s : String) -> String {
  let b = StringBuilder()
  for c in s {
    b.write_char(if c >= 'a' && c <= 'z' { Int::unsafe_to_char(c.to_int() - 32) } else { c })
  }
  b.to_string()
}

///|
/// JavaScript's toUpperCase of one string (what model names hold: ASCII, else left to the ASCII rule).
fn upper_first(w : String) -> String {
  if w == "" {
    return ""
  }
  let first = u(w, 0)
  let rest = slice(w, 1)
  let up = if first >= 'a'.to_int() && first <= 'z'.to_int() { first - 32 } else { first }
  Int::unsafe_to_char(up).to_string() + rest
}

///|
fn word(w : String) -> String {
  match brand(w) {
    Some(b) => b
    None => if size_word(w) { upper_ascii(w) } else { upper_first(w) }
  }
}

///|
fn joined(words : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for w in words {
    let n = out.length()
    if n > 0 &&
      out[n - 1].length() > 0 &&
      is_digit_unit(u(out[n - 1], out[n - 1].length() - 1)) &&
      w.length() >= 1 &&
      w.length() <= 2 &&
      digits_only(w) {
      out[n - 1] = out[n - 1] + "." + w
    } else {
      out.push(w)
    }
  }
  out
}

///|
fn effort_short(e : String) -> String? {
  match e {
    "low" => Some("低")
    "medium" => Some("中")
    "high" => Some("高")
    "xhigh" => Some("超高")
    "max" => Some("最高")
    _ => None
  }
}

///|
let known_families : Array[String] = [
  "gpt", "glm", "codex", "deepseek", "qwen", "qwq", "gemini", "gemma", "kimi", "moonshot",
  "minimax", "grok", "mistral", "devstral", "codestral", "llama", "doubao", "hunyuan", "ernie",
  "nemotron", "muse", "adaptive",
]

///|
fn named_model(base : String) -> String? {
  if base.has_prefix("fusion-") {
    let split_at = index_of(base, "-sidekick-")
    if split_at > 7 {
      let lead_raw = slice(base, 7, to=split_at)
      let side_raw = slice(base, split_at + 10)
      if side_raw != "" {
        let (lead_base, _) = agy_base_model(lead_raw)
        let (side_base, side_effort) = agy_base_model(side_raw)
        let lead = named_model(lead_base).unwrap_or(lead_base)
        let side = named_model(side_base).unwrap_or(side_base)
        return match side_effort {
          Some(e) => Some("\{lead} + \{side} (\{effort_short(e).unwrap_or(word(e))})")
          None => Some("\{lead} + \{side}")
        }
      }
    }
  }
  let words = split(base, "-").filter(w => w != "")
  if words.length() == 0 {
    return None
  }
  let first = words[0]
  if first == "claude" || claude_families.contains(first) {
    let family = match words.iter().find_first(w => claude_families.contains(w)) {
      Some(f) => f
      None => return None
    }
    let version = words.filter(digits_only)
    let rest = words.filter(w => w != "claude" && w != family && !digits_only(w)).map(word)
    let parts = [word(family)]
    if version.length() > 0 {
      parts.push(version.join("."))
    }
    return Some((parts + rest).join(" "))
  }
  let parts = joined(words)
  let dashed = if ["gpt", "glm", "swe"].contains(first) { Some(word(first)) } else { None }
  match dashed {
    Some(d) if parts.length() > 1 => {
      let second = brand(parts[1]).unwrap_or(parts[1])
      let tail = parts[2:].to_owned().map(word)
      return Some((["\{d}-\{second}"] + tail).join(" "))
    }
    _ => ()
  }
  let o_series = first.length() > 1 && first.has_prefix("o") && digits_only(slice(first, 1))
  // first.replace(/[0-9.]+$/, "")
  let mut end = first.length()
  while end > 0 && (is_digit_unit(u(first, end - 1)) || u(first, end - 1) == '.'.to_int()) {
    end -= 1
  }
  let family = slice(first, 0, to=end)
  if !o_series && !known_families.contains(family) {
    return None
  }
  let out = []
  for i, w in parts {
    out.push(if i == 0 && o_series { w } else { word(w) })
  }
  Some(out.join(" "))
}

///|
/// model-name.ts `modelName`: a model as people call it (Opus 5.5, GPT-6 Astra); one of a family not known here reads
/// as it is spelled.
pub fn model_name(id : String) -> String {
  let k = @readops.model_key(id)
  let at = index_of(k, "[")
  let (base, context) = if at >= 0 {
    let inner = slice(k, at + 1)
    let mut end = inner.length()
    while end > 0 && u(inner, end - 1) == ']'.to_int() {
      end -= 1
    }
    (slice(k, 0, to=at), @jscase.lower(slice(inner, 0, to=end)) |> upper_text)
  } else {
    (k, "")
  }
  match named_model(base) {
    None => trim(id)
    Some(named) => if context == "" { named } else { "\{named} \{context}" }
  }
}

///|
fn upper_text(s : String) -> String {
  upper_ascii(s)
}
