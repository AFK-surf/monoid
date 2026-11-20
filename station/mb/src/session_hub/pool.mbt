// The account pool (station/src/sessions/pool.ts): delegates the pure pool, urgency, context-compaction and
// reasoning-level rules to @accounts_pool, adapting Json <-> JValue at the boundary.

///|
/// What the pool reads of the station as it picks.
pub struct PoolSignals {
  health : (String) -> Json
  /// Sessions with a live process on this profile.
  load : (String) -> Int
  /// When the pool last chose this profile (0 if never).
  last_picked : (String) -> Double
  now : () -> Double
}

///|
/// rows.ts `COMPACTED_FROM`: a context falling under half of what the call before sent, from at least this much.
pub let compacted_from : Double = @accounts_pool.compacted_from

///|
fn to_jv(v : Json) -> @jsjson.JValue {
  @jsjson.jval_of_json(v)
}

///|
fn to_opt_jv(v : Json?) -> @jsjson.JValue? {
  v.map(to_jv)
}

///|
fn health_of(h : Json) -> @accounts_pool.Health {
  @accounts_pool.Health::of_jv(to_jv(h))
}

///|
/// `windowsOf`.
pub fn windows_of(quota : Json?) -> Array[Json] {
  @accounts_pool.windows_of(to_opt_jv(quota)).map(@jsjson.jval_to_json)
}

///|
/// `urgency`: `{crowded, pace, weight}` of a profile's allowance.
pub fn urgency(quota : Json?, now : Double) -> Json {
  let u = @accounts_pool.urgency(to_opt_jv(quota), now)
  { "crowded": Json::boolean(u.crowded), "pace": num(u.pace), "weight": num(u.weight) }
}

///|
/// `cheapToLeave`: whether a session loses little by going on afresh on another account, by its last main-thread
/// calls (`{turn, profile, model, context}`, oldest first) and where each model is compacted on this station.
pub fn cheap_to_leave(calls : Array[Json], points : Map[String, Double]) -> Bool {
  let adapted : Array[@accounts_pool.ContextCall] = calls.map(c => {
    turn: match field(c, "turn") {
      Some(String(t)) => @jsjson.Str(t)
      _ => @jsjson.Null
    },
    profile: str_of(c, "profile"),
    model: str_of(c, "model"),
    context: num_of(c, "context"),
  })
  @accounts_pool.cheap_to_leave(adapted, points)
}

///|
/// `signsIn`: its login is not over and its key was not rejected.
pub fn signs_in(health : Json) -> Bool {
  @accounts_pool.signs_in(health_of(health))
}

///|
/// `usable`: it signs in, none of its windows is used up, and no turn ran into its allowance since.
pub fn usable(health : Json, now : Double?) -> Bool {
  @accounts_pool.usable(health_of(health), now?)
}

///|
/// `pickProfile`: `strict` (a chat started by hand): a profile must run the model; otherwise profiles with it are
/// preferred, and without any the bound ones still serve.
pub fn pick_profile(candidates : Array[Json], model : String?, signals : PoolSignals, strict : Bool) -> Json raise Refused {
  let profiles = candidates.map(p => @accounts_pool.Profile::of_hub(to_jv(p)))
  let ps : @accounts_pool.PoolSignals = {
    health: id => health_of((signals.health)(id)),
    load: signals.load,
    last_picked: signals.last_picked,
    now: signals.now,
  }
  let chosen = @accounts_pool.pick_profile(profiles, model, ps, strict) catch {
    e => raise Refused(@accounts_pool.message_of(e))
  }
  chosen.raw.to_json()
}

// ── reasoning levels (client/core-ts/src/shapes/reasoning.ts) ──

///|
/// `fallbackEfforts` and `commonEfforts`, delegated to `@accounts_pool`.
pub using @accounts_pool {fallback_efforts, common_efforts}

///|
/// `reportedEfforts`: the levels a model's runtime reported (an empty list: none), None where it has reported none.
/// `catalog`: runtime → model → levels.
pub fn reported_efforts(runtime : String, model : String?, catalog : Json?) -> Array[String]? {
  @accounts_pool.reported_efforts(runtime, model, to_opt_jv(catalog))
}

///|
/// `availableEfforts`: as its runtime reported them, else the runtime's usual ones.
pub fn available_efforts(runtime : String, model : String?, catalog : Json?) -> Array[String] {
  @accounts_pool.available_efforts(runtime, model, to_opt_jv(catalog))
}
