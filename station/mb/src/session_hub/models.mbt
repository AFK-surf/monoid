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
  @accounts_pool.spelling(@accounts_pool.Profile::of_hub(to_jv(profile)), model)
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
  @accounts_pool.allowed_in(@accounts_pool.Profile::of_hub(to_jv(profile)), ws, home)
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
/// model-name.ts `modelName`, delegated to `@ops_platform`.
pub using @ops_platform {model_name}
