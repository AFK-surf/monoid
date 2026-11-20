// The account pool (station/src/sessions/pool.ts): which of a station's profiles a session runs on, by their checks
// and allowances: profiles that run the chosen model, those that can run now, those paid for already first; of the
// rest, one whose short window is nearly full last, the others sharing the sessions by weight (how fast each has to
// spend not to lose any of its long window, times what is left of its short one); even, the one picked least
// recently. Also the reasoning levels a model offers, which the pool's accounts decide.

///|
/// How a profile is doing (`ProfileHealth`): its last check and allowance, the account whose allowance it uses where
/// known, and whether a turn ran into that allowance since it was last read.
pub(all) struct Health {
  check : JV?
  quota : JV?
  account : String?
  spent : Bool
} derive(Eq)

///|
pub fn Health::empty() -> Health {
  { check: None, quota: None, account: None, spent: false }
}

///|
/// As JSON (`{check, quota, account?, spent?}`), null where a part is null.
pub fn Health::to_jv(self : Health) -> JV {
  let fields = [
    ("check", self.check.unwrap_or(Null)),
    ("quota", self.quota.unwrap_or(Null)),
  ]
  if self.account is Some(a) {
    fields.push(("account", js(a)))
  }
  if self.spent {
    fields.push(("spent", jbool(true)))
  }
  jobj(fields)
}

///|
/// From JSON as a part gives it (`{check?, quota?, account?, spent?}`).
pub fn Health::of_jv(v : JV) -> Health {
  {
    check: match v.get("check") {
      None | Some(Null) => None
      x => if is_undef(x.unwrap()) { None } else { x }
    },
    quota: match v.get("quota") {
      None | Some(Null) => None
      x => if is_undef(x.unwrap()) { None } else { x }
    },
    account: match v.get("account") {
      Some(Str(a)) => Some(a)
      _ => None
    },
    spent: v.get("spent") == Some(Bool(true)),
  }
}

///|
let day_ms : Double = 86_400_000.0

///|
let crowded_percent : Double = 80.0

///|
let min_weight : Double = 0.01

///|
/// JavaScript's `Number(v)`.
pub fn to_number(v : JV?) -> Double {
  match v {
    None => @double.not_a_number
    Some(Null) => 0.0
    Some(Bool(b)) => if b { 1.0 } else { 0.0 }
    Some(Num(n)) => n
    Some(Str(s)) => js_number(s)
    Some(Arr(a)) =>
      if a.length() == 0 {
        0.0
      } else if a.length() == 1 {
        to_number(Some(Str(js_string(Some(a[0])))))
      } else {
        @double.not_a_number
      }
    Some(Obj(_) as o) => if is_undef(o) { @double.not_a_number } else { @double.not_a_number }
  }
}

///|
/// `Math.max(a, b)`: NaN where either is.
pub fn js_max(a : Double, b : Double) -> Double {
  if a.is_nan() || b.is_nan() {
    @double.not_a_number
  } else if a > b {
    a
  } else if b > a {
    b
  } else if a == 0.0 && b == 0.0 {
    // +0 over -0
    if (1.0 / a) > 0.0 {
      a
    } else {
      b
    }
  } else {
    a
  }
}

///|
/// `Math.min(a, b)`: NaN where either is.
pub fn js_min(a : Double, b : Double) -> Double {
  if a.is_nan() || b.is_nan() {
    @double.not_a_number
  } else if a < b {
    a
  } else if b < a {
    b
  } else if a == 0.0 && b == 0.0 {
    if (1.0 / a) < 0.0 {
      a
    } else {
      b
    }
  } else {
    a
  }
}

///|
/// `Math.max(...xs)` (-Infinity of none).
pub fn js_max_of(xs : Array[Double]) -> Double {
  let mut m = @double.neg_infinity
  for x in xs {
    m = js_max(m, x)
  }
  m
}

///|
/// `Math.min(...xs)` (Infinity of none).
pub fn js_min_of(xs : Array[Double]) -> Double {
  let mut m = @double.infinity
  for x in xs {
    m = js_min(m, x)
  }
  m
}

///|
fn num_field(w : JV, k : String) -> Double? {
  match w.get(k) {
    Some(Num(n)) => Some(n)
    _ => None
  }
}

///|
/// `windowsOf`: an allowance's windows, where it is ok.
pub fn windows_of(quota : JV?) -> Array[JV] {
  match quota {
    Some(Obj(_) as q) if q.get("state") == Some(Str("ok")) =>
      match q.get("windows") {
        Some(Arr(a)) => a
        _ => []
      }
    _ => []
  }
}

///|
fn fresh_windows(quota : JV?, now : Double?) -> Array[JV] {
  windows_of(quota).map(w => match (now, num_field(w, "resetsAt")) {
    (Some(t), Some(r)) if r <= t => jset(w, "usedPercent", jnum(0.0))
    _ => w
  })
}

///|
/// How much of its tightest window a profile has used; unknown counts as half.
fn used(quota : JV?, now : Double?) -> Double {
  let windows = fresh_windows(quota, now)
  if windows.length() > 0 {
    let mut m = -@double.max_value
    for w in windows {
      m = js_max(m, to_number(w.get("usedPercent")))
    }
    return m
  }
  50.0
}

///|
pub(all) struct Urgency {
  crowded : Bool
  pace : Double
  weight : Double
}

///|
/// `urgency`: how a profile's allowance ranks.
pub fn urgency(quota : JV?, now : Double) -> Urgency {
  let windows = fresh_windows(quota, Some(now)).filter(w => match num_field(w, "minutes") {
    Some(m) => m > 0.0
    None => false
  })
  let minutes = (w : JV) => num_field(w, "minutes").unwrap_or(0.0)
  let long = windows.filter(w => minutes(w) * 60000.0 > day_ms)
  let short = windows.filter(w => minutes(w) * 60000.0 <= day_ms)
  let crowded = long.length() > 0 &&
    short.iter().any(w => to_number(w.get("usedPercent")) >= crowded_percent)
  let room = if long.length() > 0 {
    let mut m = 1.0
    for w in short {
      m = js_min(m, js_max(0.0, 100.0 - to_number(w.get("usedPercent"))) / 100.0)
    }
    m
  } else {
    1.0
  }
  let weighted = (crowded : Bool, pace : Double) => {
    { crowded, pace, weight: js_max(pace * room, min_weight) }
  }
  let has_reset = (w : JV) => num_field(w, "resetsAt") is Some(_)
  let weighed = (if long.length() > 0 { long } else { short }).filter(has_reset)
  if weighed.length() == 0 {
    return weighted(crowded, (100.0 - used(quota, Some(now))) / 100.0)
  }
  let paces = weighed.map(w => {
    let left = js_max(0.0, 100.0 - to_number(w.get("usedPercent"))) / 100.0
    let length = minutes(w) * 60000.0
    let resets = num_field(w, "resetsAt").unwrap_or(0.0)
    let ahead = js_max(resets - now, 0.0)
    let remaining = js_min(
      length,
      if ahead == 0.0 || ahead.is_nan() {
        length
      } else {
        ahead
      },
    )
    left * length /
    (if length > day_ms { js_max(remaining, day_ms) } else { remaining })
  })
  weighted(crowded, js_min_of(paces))
}

///|
pub let compacted_from : Double = 50_000.0

///|
let near_compaction : Double = 0.75

///|
/// One of a session's last main-thread calls (`ContextCall`).
pub(all) struct ContextCall {
  turn : JV
  profile : String?
  model : String?
  context : Double?
}

///|
/// `cheapToLeave`: whether a session loses little by going on afresh on another account.
pub fn cheap_to_leave(
  calls : Array[ContextCall],
  points : Map[String, Double],
) -> Bool {
  if calls.length() == 0 {
    return false
  }
  let last = calls[calls.length() - 1]
  let point = match last.model {
    None => None
    Some(m) => points.get(m)
  }
  match (point, last.context) {
    (Some(p), Some(c)) if c >= p * near_compaction => return true
    _ => ()
  }
  let distinct : Array[JV] = []
  for c in calls {
    if !distinct.contains(c.turn) {
      distinct.push(c.turn)
    }
  }
  let turns = if distinct.length() > 2 {
    distinct[distinct.length() - 2:].to_array()
  } else {
    distinct
  }
  for i, c in calls {
    if i == 0 {
      continue
    }
    let before = calls[i - 1]
    match (before.context, c.context) {
      (Some(b), Some(x)) =>
        if turns.contains(c.turn) &&
          b >= compacted_from &&
          x * 2.0 < b &&
          c.profile == before.profile &&
          c.model == before.model {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
/// `signsIn`: its login is not over, its key was not rejected, and the provider has not blocked it.
pub fn signs_in(h : Health) -> Bool {
  let state = jget(h.check, "state")
  state != Some(Str("login")) &&
  state != Some(Str("failed")) &&
  jget(h.quota, "state") != Some(Str("blocked"))
}

///|
/// `quotaUnavailable`: whether a profile's last allowance check could not read its quota.
fn quota_unavailable(h : Health) -> Bool {
  jget(h.quota, "state") == Some(Str("unavailable"))
}

///|
/// `usable`: it can run now.
pub fn usable(h : Health, now? : Double) -> Bool {
  !h.spent && signs_in(h) && used(h.quota, now) < 100.0
}

///|
/// `serves`: a chosen model needs the profile to run it; none, its own default.
pub fn serves(p : Profile, model : String?) -> Bool {
  match model {
    None => true
    Some(m) => runs(p, m)
  }
}

///|
/// What the pool is told of the profiles (`PoolSignals`).
pub(all) struct PoolSignals {
  health : (String) -> Health
  load : (String) -> Int
  last_picked : (String) -> Double
  now : () -> Double
}

///|
/// A stable sort by a comparator as JavaScript's (`Array.prototype.sort`, NaN as equal).
pub fn[T] stable_sort(xs : Array[T], cmp : (T, T) -> Double) -> Unit {
  // insertion sort: stable, and the lists are short
  for i in 1..<xs.length() {
    let x = xs[i]
    let mut j = i - 1
    while j >= 0 {
      let c = cmp(xs[j], x)
      if c > 0.0 {
        xs[j + 1] = xs[j]
        j -= 1
      } else {
        break
      }
    }
    xs[j + 1] = x
  }
}

///|
/// `a || b` of two comparisons (0 and NaN fall through).
fn or_else(a : Double, b : () -> Double) -> Double {
  if a == 0.0 || a.is_nan() {
    b()
  } else {
    a
  }
}

///|
/// `pickProfile`. `strict` (a chat started by hand): a profile must run the model.
pub fn pick_profile(
  candidates : Array[Profile],
  model : String?,
  signals : PoolSignals,
  strict : Bool,
) -> Profile raise Thrown {
  if candidates.length() == 0 {
    raise plain_error("no profile to run on")
  }
  let rank = candidates.map(p => (p, (signals.health)(p.id)))
  let mut serving = []
  for i, r in rank {
    if serves(r.0, model) {
      serving.push(i)
    }
  }
  if serving.length() == 0 {
    if strict {
      raise plain_error(
        "no profile has \{model.unwrap_or("")} enabled; enable it on a profile first",
      )
    }
    serving = Array::makei(rank.length(), i => i)
  }
  let now = (signals.now)()
  let fit = serving.filter(i => usable(rank[i].1, now~))
  let paid = fit.filter(i => !billed_per_use(rank[i].0.raw))
  let signed_in = serving.filter(i => signs_in(rank[i].1))
  let healthy = (list : Array[Int]) => list.filter(i => !quota_unavailable(rank[i].1))
  let paid_healthy = healthy(paid)
  let fit_healthy = healthy(fit)
  let signed_in_healthy = healthy(signed_in)
  let pool = if paid_healthy.length() > 0 {
    paid_healthy
  } else if paid.length() > 0 {
    paid
  } else if fit_healthy.length() > 0 {
    fit_healthy
  } else if fit.length() > 0 {
    fit
  } else if signed_in_healthy.length() > 0 {
    signed_in_healthy
  } else if signed_in.length() > 0 {
    signed_in
  } else {
    serving
  }
  let urgencies : Map[Int, Urgency] = Map::new()
  for i in pool {
    urgencies[i] = urgency(rank[i].1.quota, now)
  }
  let share = (i : Int) => ((signals.load)(rank[i].0.id) + 1).to_double() /
    urgencies[i].weight
  let crowded = (b : Bool) => if b { 1.0 } else { 0.0 }
  let sorted = pool.copy()
  stable_sort(sorted, (a, b) => {
    let ua = urgencies[a]
    let ub = urgencies[b]
    or_else(crowded(ua.crowded) - crowded(ub.crowded), () => or_else(
      share(a) - share(b),
      () => (signals.last_picked)(rank[a].0.id) -
        (signals.last_picked)(rank[b].0.id),
    ))
  })
  rank[sorted[0]].0
}

// ── reasoning levels ──

///|
/// `fallbackEfforts`: a runtime's usual levels.
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
fn levels_of(v : JV) -> Array[String] {
  jitems(Some(v)).map(x => match x {
    Str(s) => s
    other => js_string(Some(other))
  })
}

///|
/// `reportedEfforts`: the levels a model's runtime reported, None where it has reported none.
pub fn reported_efforts(
  runtime : String,
  model : String?,
  catalog : JV?,
) -> Array[String]? {
  let models = match jget(catalog, runtime) {
    Some(Null) | None => return None
    Some(m) => m
  }
  guard model is Some(model) else { return None }
  let base = if runtime == "agy" {
    agy_base_model(model)
  } else if runtime == "devin" {
    match devin_fusion_split(model) {
      Some((lead, _, _)) => lead
      None => model
    }
  } else {
    model
  }
  let pick = (v : JV?) => match v {
    None | Some(Null) => None
    Some(x) => Some(x)
  }
  match pick(models.get(model)) {
    Some(l) => return Some(levels_of(l))
    None => ()
  }
  match pick(models.get(base)) {
    Some(l) => return Some(levels_of(l))
    None => ()
  }
  for p in jfields(Some(models)) {
    if same_model(p.0, model) || (base != model && same_model(p.0, base)) {
      return match p.1 {
        Null => None
        l => Some(levels_of(l))
      }
    }
  }
  None
}

///|
/// `availableEfforts`.
pub fn available_efforts(
  runtime : String,
  model : String?,
  catalog : JV?,
) -> Array[String] {
  reported_efforts(runtime, model, catalog).unwrap_or(fallback_efforts(runtime))
}

///|
/// `commonEfforts`: the levels every one of these offers.
pub fn common_efforts(
  profiles : Array[Array[String]],
  runtime : String,
) -> Array[String] {
  if profiles.length() == 0 {
    return available_efforts(runtime, None, None)
  }
  let first = profiles[0]
  first.filter(level => {
    for i in 1..<profiles.length() {
      if !profiles[i].contains(level) {
        return false
      }
    }
    true
  })
}
