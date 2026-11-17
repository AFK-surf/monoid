// The account pool (station/src/sessions/pool.ts): which of a station's profiles a session runs on. Only profiles with
// the chosen model qualify; of those, one whose check says it cannot sign in or was rejected, or whose allowance is
// used up, is passed over. Accounts paid for already go first; one billed per use runs a session only when none of
// them can. Of the rest: one whose short window is nearly full goes last; the others share the sessions by weight,
// each new one going where (sessions + 1) ÷ weight is least; even, the one picked least recently. Also the reasoning
// levels a model offers. A profile's health is `{check?, quota?, account?, spent?}` as JSON.

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
let day_ms : Double = 86_400_000.0

///|
let crowded_percent : Double = 80.0

///|
let min_weight : Double = 0.01

///|
/// rows.ts `COMPACTED_FROM`: a context falling under half of what the call before sent, from at least this much.
pub let compacted_from : Double = 50_000.0

///|
let near_compaction : Double = 0.75

///|
/// `windowsOf`.
pub fn windows_of(quota : Json?) -> Array[Json] {
  match quota {
    Some(Object(_) as q) if str_of(q, "state") == Some("ok") => items(field(q, "windows"))
    _ => []
  }
}

///|
/// `Number(v)` of a window's field as JavaScript reads it.
fn js_num(v : Json?) -> Double {
  match v {
    Some(Number(n, ..)) => n
    Some(Null) => 0.0
    None => @double.not_a_number
    Some(True) => 1.0
    Some(False) => 0.0
    Some(String(s)) => {
      let t = trim(s)
      if t == "" {
        0.0
      } else {
        js_number(Json::string(t)).unwrap_or(@double.not_a_number)
      }
    }
    Some(_) => @double.not_a_number
  }
}

///|
/// A profile's windows, with `now` one whose refill is due as empty.
fn fresh_windows(quota : Json?, now : Double?) -> Array[Json] {
  windows_of(quota).map(w => match (now, num_of(w, "resetsAt")) {
    (Some(n), Some(at)) if at <= n => {
      let copy = match w {
        Object(m) => m.copy()
        _ => {}
      }
      copy["usedPercent"] = num(0.0)
      Json::object(copy)
    }
    _ => w
  })
}

///|
/// Math.max as JavaScript has it (NaN wins).
fn js_max(a : Double, b : Double) -> Double {
  if a.is_nan() || b.is_nan() {
    @double.not_a_number
  } else if a > b {
    a
  } else {
    b
  }
}

///|
fn js_min(a : Double, b : Double) -> Double {
  if a.is_nan() || b.is_nan() {
    @double.not_a_number
  } else if a < b {
    a
  } else {
    b
  }
}

///|
/// How much of its tightest window a profile has used, 0–100; unknown counts as half.
fn used(quota : Json?, now : Double?) -> Double {
  let windows = fresh_windows(quota, now)
  if windows.length() > 0 {
    let mut m = -@double.max_value
    for w in windows {
      m = js_max(m, js_num(field(w, "usedPercent")))
    }
    return m
  }
  50.0
}

///|
/// `urgency`: `{crowded, pace, weight}` of a profile's allowance.
pub fn urgency(quota : Json?, now : Double) -> Json {
  let (crowded, pace, weight) = urgency_of(quota, now)
  { "crowded": Json::boolean(crowded), "pace": num(pace), "weight": num(weight) }
}

///|
fn urgency_of(quota : Json?, now : Double) -> (Bool, Double, Double) {
  let windows = fresh_windows(quota, Some(now)).filter(w => match num_of(w, "minutes") {
    Some(m) => m > 0.0
    None => false
  })
  let minutes = (w : Json) => num_of(w, "minutes").unwrap_or(0.0)
  let long = windows.filter(w => minutes(w) * 60_000.0 > day_ms)
  let short = windows.filter(w => minutes(w) * 60_000.0 <= day_ms)
  let crowded = long.length() > 0 &&
    short.iter().any(w => js_num(field(w, "usedPercent")) >= crowded_percent)
  let room = if long.length() > 0 {
    let mut r = 1.0
    for w in short {
      r = js_min(r, js_max(0.0, 100.0 - js_num(field(w, "usedPercent"))) / 100.0)
    }
    r
  } else {
    1.0
  }
  let weighted = (pace : Double) => (crowded, pace, js_max(pace * room, min_weight))
  let weighed = (if long.length() > 0 { long } else { short }).filter(w => num_of(w, "resetsAt") is Some(_))
  if weighed.length() == 0 {
    return weighted((100.0 - used(quota, Some(now))) / 100.0)
  }
  let mut pace = @double.infinity
  for w in weighed {
    let left = js_max(0.0, 100.0 - js_num(field(w, "usedPercent"))) / 100.0
    let length = minutes(w) * 60_000.0
    let until = js_max(num_of(w, "resetsAt").unwrap_or(0.0) - now, 0.0)
    // (`x || length`: a refill already due, NaN too, counts the whole window)
    let remaining = js_min(length, if until == 0.0 || until.is_nan() { length } else { until })
    let p = left * length / (if length > day_ms { js_max(remaining, day_ms) } else { remaining })
    pace = js_min(pace, p)
  }
  weighted(pace)
}

///|
/// `cheapToLeave`: whether a session loses little by going on afresh on another account, by its last main-thread
/// calls (`{turn, profile, model, context}`, oldest first) and where each model is compacted on this station.
pub fn cheap_to_leave(calls : Array[Json], points : Map[String, Double]) -> Bool {
  if calls.length() == 0 {
    return false
  }
  let last = calls[calls.length() - 1]
  match (str_of(last, "model"), num_of(last, "context")) {
    (Some(m), Some(c)) =>
      match points.get(m) {
        Some(point) => if c >= point * near_compaction { return true }
        None => ()
      }
    _ => ()
  }
  let turn_key = (c : Json) => match field(c, "turn") {
    Some(String(t)) => Some(t)
    _ => None
  }
  let distinct : Array[String?] = []
  for c in calls {
    let t = turn_key(c)
    if !distinct.contains(t) {
      distinct.push(t)
    }
  }
  let turns = distinct[@cmp.maximum(0, distinct.length() - 2):].to_owned()
  for i, c in calls {
    if i == 0 {
      continue
    }
    let before = calls[i - 1]
    match (num_of(before, "context"), num_of(c, "context")) {
      (Some(b), Some(x)) =>
        if turns.contains(turn_key(c)) &&
          b >= compacted_from &&
          x * 2.0 < b &&
          same(field(c, "profile"), field(before, "profile")) &&
          same(field(c, "model"), field(before, "model")) {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
/// `signsIn`: its login is not over and its key was not rejected.
pub fn signs_in(health : Json) -> Bool {
  let state = match field(health, "check") {
    Some(Object(_) as c) => str_of(c, "state")
    _ => None
  }
  state != Some("login") && state != Some("failed")
}

///|
/// `usable`: it signs in, none of its windows is used up, and no turn ran into its allowance since.
pub fn usable(health : Json, now : Double?) -> Bool {
  !is_true(health, "spent") &&
  signs_in(health) &&
  used(
    match field(health, "quota") {
      Some(Null) => None
      q => q
    },
    now,
  ) <
  100.0
}

///|
/// `pickProfile`: `strict` (a chat started by hand): a profile must run the model; otherwise profiles with it are
/// preferred, and without any the bound ones still serve.
pub fn pick_profile(candidates : Array[Json], model : String?, signals : PoolSignals, strict : Bool) -> Json raise Refused {
  if candidates.length() == 0 {
    raise Refused("no profile to run on")
  }
  let rank = candidates.map(p => (p, (signals.health)(profile_id(p))))
  let mut serving = []
  for i, r in rank {
    if serves(r.0, model) {
      serving.push(i)
    }
  }
  if serving.length() == 0 {
    if strict {
      raise Refused("no profile has \{model.unwrap_or("")} enabled; enable it on a profile first")
    }
    serving = Array::makei(rank.length(), i => i)
  }
  let now = (signals.now)()
  let fit = serving.filter(i => usable(rank[i].1, Some(now)))
  let paid = fit.filter(i => !billed_per_use(rank[i].0))
  let signed_in = serving.filter(i => signs_in(rank[i].1))
  let pool = if paid.length() > 0 {
    paid
  } else if fit.length() > 0 {
    fit
  } else if signed_in.length() > 0 {
    signed_in
  } else {
    serving
  }
  let urgencies : Map[Int, (Bool, Double, Double)] = Map([])
  for i in pool {
    urgencies[i] = urgency_of(
      match field(rank[i].1, "quota") {
        Some(Null) => None
        q => q
      },
      now,
    )
  }
  let share = (i : Int) => ((signals.load)(profile_id(rank[i].0)) + 1).to_double() /
    urgencies.get(i).unwrap().2
  let sorted = stable_sort(pool, (a, b) => {
    let ua = urgencies.get(a).unwrap()
    let ub = urgencies.get(b).unwrap()
    let c = (if ua.0 { 1 } else { 0 }) - (if ub.0 { 1 } else { 0 })
    if c != 0 {
      return c
    }
    let s = share(a) - share(b)
    if s != 0.0 && !s.is_nan() {
      return if s > 0.0 { 1 } else { -1 }
    }
    let l = (signals.last_picked)(profile_id(rank[a].0)) -
      (signals.last_picked)(profile_id(rank[b].0))
    if l > 0.0 {
      1
    } else if l < 0.0 {
      -1
    } else {
      0
    }
  })
  rank[sorted[0]].0
}

// ── reasoning levels (client/core-ts/src/shapes/reasoning.ts) ──

///|
/// `fallbackEfforts`.
pub fn fallback_efforts(runtime : String) -> Array[String] {
  match runtime {
    "codex" => ["minimal", "low", "medium", "high", "xhigh"]
    "dsh" => ["low", "medium", "high", "max"]
    "grok" => ["low", "medium", "high", "xhigh"]
    "cursor" | "hermes" | "agy" => []
    "devin" => ["low", "medium", "high", "xhigh", "max"]
    _ => ["low", "medium", "high", "xhigh", "max"]
  }
}

///|
fn strings_of(v : Json) -> Array[String] {
  items(Some(v)).map(js_string)
}

///|
/// `reportedEfforts`: the levels a model's runtime reported (an empty list: none), None where it has reported none.
/// `catalog`: runtime → model → levels.
pub fn reported_efforts(runtime : String, model : String?, catalog : Json?) -> Array[String]? {
  let models = match catalog {
    Some(Object(_) as c) =>
      match field(c, runtime) {
        Some(Object(m)) => m
        _ => return None
      }
    _ => return None
  }
  let model = match model {
    None => return None
    Some(m) => m
  }
  let base = if runtime == "agy" {
    agy_base_model(model).0
  } else if runtime == "devin" {
    match split_devin_fusion(model) {
      Some((lead, _, _)) => lead
      None => model
    }
  } else {
    model
  }
  match models.get(model) {
    Some(l) if l != Json::null() => return Some(strings_of(l))
    _ => ()
  }
  match models.get(base) {
    Some(l) if l != Json::null() => return Some(strings_of(l))
    _ => ()
  }
  for id, l in models {
    if same_model(id, model) || (base != model && same_model(id, base)) {
      return if l == Json::null() { None } else { Some(strings_of(l)) }
    }
  }
  None
}

///|
/// `availableEfforts`: as its runtime reported them, else the runtime's usual ones.
pub fn available_efforts(runtime : String, model : String?, catalog : Json?) -> Array[String] {
  match reported_efforts(runtime, model, catalog) {
    Some(l) => l
    None => fallback_efforts(runtime)
  }
}

///|
/// `commonEfforts`: the levels every one of these offers.
pub fn common_efforts(profiles : Array[Array[String]], runtime : String) -> Array[String] {
  if profiles.length() == 0 {
    return available_efforts(runtime, None, None)
  }
  let first = profiles[0]
  first.filter(level => profiles[1:].iter().all(o => o.contains(level)))
}
