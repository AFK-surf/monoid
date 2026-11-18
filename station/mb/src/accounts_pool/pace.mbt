// GET /profiles/pace (station/src/accounts/pace.ts): each account's last PACE_HOURS hours as its Profile overview draws
// them: what its allowance said in each hour, and what its calls spent in each, as dollars at list prices by the window
// they count against (`scope`). The prices are the model catalog's where it names one (station/src/accounts/catalog.ts
// `facts`, given as it last said), else the station's own table's (station/src/read/usage.ts `PRICES`, `price`).

///|
pub let hour_ms : Double = 3_600_000.0

///|
pub let pace_hours : Double = 192.0

///|
/// A model's API prices, in dollars per million tokens.
pub(all) struct Price {
  input : Double
  output : Double
  cache_read : Double
} derive(Eq, Show)

///|
fn pr(input : Double, output : Double, cache_read : Double) -> Price {
  { input, output, cache_read }
}

///|
/// Standard short-context API list prices, longer names first (read/usage.ts `PRICES`).
pub let prices : Array[(String, Price)] = [
  ("gpt-6-astra", pr(10.0, 50.0, 1.0)),
  ("gpt-6.1-sol", pr(2.0, 10.0, 0.1)),
  ("gpt-6.1-terra", pr(1.0, 5.0, 0.05)),
  ("gpt-6-sol", pr(2.0, 10.0, 0.2)),
  ("gpt-6-luna", pr(0.1, 0.5, 0.01)),
  ("gpt-5.6-sol", pr(4.0, 20.0, 0.4)),
  ("claude-fable-5-2", pr(8.0, 40.0, 0.2)),
  ("claude-fable-5-1", pr(10.0, 50.0, 0.25)),
  ("claude-mythos-5-1", pr(10.0, 50.0, 0.25)),
  ("claude-fable-5", pr(10.0, 50.0, 1.0)),
  ("claude-mythos-5", pr(10.0, 50.0, 1.0)),
  ("claude-opus-5-5", pr(4.0, 20.0, 0.2)),
  ("claude-opus-5", pr(5.0, 25.0, 0.5)),
  ("claude-opus-4-8", pr(5.0, 25.0, 0.5)),
  ("claude-opus-4-7", pr(5.0, 25.0, 0.5)),
  ("claude-opus-4-6", pr(5.0, 25.0, 0.5)),
  ("claude-opus-4-5", pr(5.0, 25.0, 0.5)),
  ("claude-sonnet-5-5", pr(2.0, 10.0, 0.1)),
  ("claude-sonnet-5", pr(2.0, 10.0, 0.2)),
  ("claude-sonnet-4-6", pr(3.0, 15.0, 0.3)),
  ("claude-sonnet-4-5", pr(3.0, 15.0, 0.3)),
  ("claude-haiku-4-5", pr(1.0, 5.0, 0.1)),
]

///|
/// What the model catalog last said, by model key (catalog.ts `learn`'s, as `catalog().models` gives it).
pub(all) struct Catalog {
  mut models : Map[String, JV]
}

///|
pub fn Catalog::new() -> Catalog {
  { models: Map::new() }
}

///|
/// The catalog as `catalog().models` has it.
pub fn Catalog::of_jv(v : JV?) -> Catalog {
  let models = Map::new()
  for f in jfields(v) {
    models[f.0] = f.1
  }
  { models, }
}

///|
/// catalog.ts `facts`: what the catalog says of a model, however a profile spells it.
pub fn Catalog::facts(self : Catalog, model : String) -> JV? {
  let key = model_key(model)
  let at = index_of(key, "[")
  let bare = if at >= 0 { slice(key, 0, b=at) } else { key }
  match self.models.get(bare) {
    Some(f) => Some(f)
    None =>
      match split_agy_tier(bare) {
        None => None
        Some((m, _)) => self.models.get(m)
      }
  }
}

///|
/// read/usage.ts `price`: a model's prices however a profile spells it, the catalog's else the table's.
pub fn Catalog::price(self : Catalog, model : String) -> Price? {
  match jget(self.facts(model), "cost") {
    Some(Obj(_) as told) => {
      let input = to_number(told.get("input"))
      let cache_read = match told.get("cacheRead") {
        None | Some(Null) => input
        x => to_number(x)
      }
      return Some({ input, output: to_number(told.get("output")), cache_read })
    }
    _ => ()
  }
  let name = model_key(model)
  let listed = (candidate : String) => {
    for p in prices {
      if candidate == p.0 ||
        (
          candidate.has_prefix(p.0) &&
          slice(candidate, p.0.length()).has_prefix("[")
        ) {
        return Some(p.1)
      }
    }
    None
  }
  match listed(name) {
    Some(p) => return Some(p)
    None => ()
  }
  let at = index_of(name, "[")
  let bare = if at >= 0 { slice(name, 0, b=at) } else { name }
  match split_agy_tier(bare) {
    None => None
    Some((m, _)) =>
      listed(if at >= 0 { m + slice(name, at) } else { m })
  }
}

///|
/// An hour of one model's calls on an account (store/profile-hours.ts `SpendHour`).
pub(all) struct SpendHour {
  hour : Double
  profile : String
  runtime : String
  model : String?
  fast : Bool
  input : Double
  cache_read : Double
  cache_write : Double
  cache_write_long : Double
  output : Double
  gen_ms : Double
  gen_output : Double
}

///|
pub fn SpendHour::of_jv(v : JV) -> SpendHour {
  let n = (k : String) => to_number(v.get(k))
  {
    hour: n("hour"),
    profile: js_string(v.get("profile")),
    runtime: js_string(v.get("runtime")),
    model: match v.get("model") {
      Some(Str(m)) => Some(m)
      _ => None
    },
    fast: is_truthy(v.get("fast")),
    input: n("input"),
    cache_read: n("cacheRead"),
    cache_write: n("cacheWrite"),
    cache_write_long: n("cacheWriteLong"),
    output: n("output"),
    gen_ms: match v.get("genMs") {
      Some(Num(x)) => x
      _ => 0.0
    },
    gen_output: match v.get("genOutput") {
      Some(Num(x)) => x
      _ => 0.0
    },
  }
}

///|
/// pace.ts `speedOf`: the calls' times of the profiles `shown` keeps (`at`, profile, model, ms, output each), added up by
/// `at` and model, in their order.
fn speed_of(rows : Array[(Double, String, String?, Double, Double)], shown : (String) -> Bool) -> JV {
  let by : Array[(Double, String, Double, Double)] = []
  for r in rows {
    let (at, profile, model, ms, output) = r
    guard shown(profile) && model is Some(m) && m != "" && ms > 0.0 else { continue }
    match by.search_by(e => e.0 == at && e.1 == m) {
      Some(i) => by[i] = (at, m, by[i].2 + output, by[i].3 + ms)
      None => by.push((at, m, output, ms))
    }
  }
  let list = by.map(e => jobj([("at", jnum(e.0)), ("model", js(e.1)), ("output", jnum(e.2)), ("ms", jnum(e.3))]))
  stable_sort(list, (a, b) => {
    let d = to_number(a.get("at")) - to_number(b.get("at"))
    if d != 0.0 && !d.is_nan() {
      return d
    }
    let c = js_compare(js_string(a.get("model")), js_string(b.get("model")))
    if c < 0 {
      -1.0
    } else if c > 0 {
      1.0
    } else {
      0.0
    }
  })
  jarr(list)
}

///|
/// JavaScript's truthiness.
pub fn is_truthy(v : JV?) -> Bool {
  match v {
    None | Some(Null) => false
    Some(Bool(b)) => b
    Some(Num(n)) => !(n == 0.0 || n.is_nan())
    Some(Str(s)) => s != ""
    Some(x) => !is_undef(x)
  }
}

///|
/// `spendWeight`: what an hour of one model's calls weighs, in dollars at its list price (a middling one where it has
/// none).
pub fn spend_weight(catalog : Catalog, s : SpendHour) -> Double {
  let p = match s.model {
    None => None
    Some(m) => catalog.price(m)
  }
  let writes = s.cache_write * 1.25 + s.cache_write_long * 2.0
  let dollars = match p {
    None =>
      (s.input + s.cache_read * 0.1 + writes + s.output * 5.0) / 1.0e6
    Some(p) =>
      (
        s.input * p.input +
        writes * p.input +
        s.cache_read * p.cache_read +
        s.output * p.output
      ) /
      1.0e6
  }
  js_max(0.0, dollars * (if s.fast { 2.0 } else { 1.0 }))
}

///|
/// `spendScopes`: the windows an hour of a runtime's model counts against ("" the account's own), by the `scope` the
/// allowance gives them: a Fable (Mythos) model's against its own week and the account's; on an Antigravity account a
/// Gemini (or Gemma) model's against "gemini", Argon's its own week too, every other model's against "3p".
pub fn spend_scopes(runtime : String, model : String?) -> Array[String] {
  let raw = lower(trim_js(model.unwrap_or("")))
  let first = split_on(raw, "[")[0]
  let slashes = split_on(first, "/")
  let mut bare = split_on(slashes[slashes.length() - 1], "@")[0]
  // `/^(?:[a-z]+\.)+/` off
  while true {
    let mut j = 0
    while j < bare.length() &&
          bare.unsafe_charcode_at(j) >= 'a'.to_int() &&
          bare.unsafe_charcode_at(j) <= 'z'.to_int() {
      j += 1
    }
    if j > 0 && j < bare.length() && bare.unsafe_charcode_at(j) == '.'.to_int() {
      bare = slice(bare, j + 1)
    } else {
      break
    }
  }
  if runtime == "claude" && (bare.contains("fable") || bare.contains("mythos")) {
    return ["Fable", ""]
  }
  if runtime == "agy" {
    if bare == "" || bare.has_prefix("gemini") || bare.has_prefix("gemma") {
      return if bare.contains("argon") { ["gemini", "Argon"] } else { ["gemini"] }
    }
    return ["3p"]
  }
  [""]
}

///|
/// JavaScript's `Math.round`.
pub fn js_round(x : Double) -> Double {
  if x.is_nan() || x.is_inf() {
    return x
  }
  let f = x.floor()
  if x - f >= 0.5 {
    f + 1.0
  } else {
    f
  }
}

///|
/// `paceView`: the view of what the store read (`{quotas, spend}`), for the profiles `shown` keeps.
pub fn pace_view(
  catalog : Catalog,
  now_at : Double,
  read : JV,
  shown : (String) -> Bool,
) -> JV {
  let now_hour = (now_at / hour_ms).floor()
  let order : Array[String] = []
  let quotas : Map[String, Array[JV]] = Map::new()
  let spends : Map[String, Array[JV]] = Map::new()
  let of = (p : String) => if !quotas.contains(p) {
    order.push(p)
    quotas[p] = []
    spends[p] = []
  }
  for q in jitems(read.get("quotas")) {
    let profile = js_string(q.get("profile"))
    if shown(profile) {
      of(profile)
      quotas[profile].push(
        jobj([
          ("hour", q.get("hour").unwrap_or(Null)),
          ("at", q.get("at").unwrap_or(Null)),
          ("windows", q.get("windows").unwrap_or(Null)),
        ]),
      )
    }
  }
  let spent_order : Array[String] = []
  let spent : Map[String, Array[(Double, String, Double)]] = Map::new()
  for raw in jitems(read.get("spend")) {
    let s = SpendHour::of_jv(raw)
    if !shown(s.profile) {
      continue
    }
    let w = spend_weight(catalog, s)
    if !(w > 0.0) {
      continue
    }
    if !spent.contains(s.profile) {
      spent_order.push(s.profile)
      spent[s.profile] = []
    }
    let by_key = spent[s.profile]
    for scope in spend_scopes(s.runtime, s.model) {
      let mut found = false
      for i, e in by_key {
        if e.0 == s.hour && e.1 == scope {
          by_key[i] = (e.0, e.1, e.2 + w)
          found = true
          break
        }
      }
      if !found {
        by_key.push((s.hour, scope, w))
      }
    }
  }
  for profile in spent_order {
    of(profile)
    let list = spends[profile]
    for e in spent[profile] {
      list.push(
        jobj([
          ("hour", jnum(e.0)),
          ("scope", js(e.1)),
          ("weight", jnum(js_round(e.2 * 1.0e6) / 1.0e6)),
        ]),
      )
    }
    stable_sort(list, (a, b) => {
      let ha = to_number(a.get("hour"))
      let hb = to_number(b.get("hour"))
      let d = ha - hb
      if d != 0.0 && !d.is_nan() {
        return d
      }
      let sa = js_string(a.get("scope"))
      let sb = js_string(b.get("scope"))
      let c = js_compare(sa, sb)
      if c < 0 {
        -1.0
      } else if c > 0 {
        1.0
      } else {
        0.0
      }
    })
  }
  let mut profiles = JV::Obj([])
  for p in order {
    profiles = jset(
      profiles,
      p,
      jobj([("quotas", jarr(quotas[p])), ("spend", jarr(spends[p]))]),
    )
  }
  let speed_hours = speed_of(
    jitems(read.get("spend")).map(raw => {
      let s = SpendHour::of_jv(raw)
      (s.hour, s.profile, s.model, s.gen_ms, s.gen_output)
    }),
    shown,
  )
  let speed_quarters = speed_of(
    jitems(read.get("speed")).map(q => (
      to_number(q.get("quarter")),
      js_string(q.get("profile")),
      match q.get("model") {
        Some(Str(m)) => Some(m)
        _ => None
      },
      to_number(q.get("genMs")),
      to_number(q.get("genOutput")),
    )),
    shown,
  )
  jobj([
    ("nowAt", jnum(now_at)),
    ("fromHour", jnum(now_hour - pace_hours)),
    ("profiles", profiles),
    ("speedHours", speed_hours),
    ("speedQuarters", speed_quarters),
  ])
}
