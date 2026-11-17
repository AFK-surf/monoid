// station/src/accounts/catalog.ts: what models can do and cost, as still.fail cloud last said (GET /v1/models), by key
// (read/usage.ts `modelKey`, station/mb readops `model_key`). Kept in one `Catalog` its part holds (models.ts' module's
// globals there), told by the models part (`module.mbt`); until it has, or for a model it does not name, the station's
// own tables answer alone.

///|
pub struct Catalog {
  priv mut told : Map[String, Json]
  priv mut version : Int
}

///|
pub fn Catalog::new() -> Catalog {
  { told: {}, version: 0 }
}

///|
/// `number`: a finite number not under 0.
fn cost_number(v : Json?) -> Double? {
  match v {
    Some(Number(n, ..)) if !n.is_nan() && !n.is_inf() && n >= 0.0 => Some(n)
    _ => None
  }
}

///|
fn strings_or(v : Json?) -> Json? {
  match v {
    Some(Array(_)) => Some(jstrings(strings_of(v)))
    _ => None
  }
}

///|
/// One model's facts as the cloud wrote them, those of a shape not known dropped (`factsOf`).
pub fn facts_of(raw : Json) -> Json? {
  guard raw is Object(r) else { return None }
  let f : Map[String, Json] = Map([])
  if r.get("name") is Some(String(s)) {
    f["name"] = Json::string(s)
  }
  for k in ["maker", "makerName", "family"] {
    if r.get(k) is Some(String(s)) && s != "" {
      f[k] = Json::string(s)
    }
  }
  if strings_or(r.get("input")) is Some(v) {
    f["input"] = v
  }
  match r.get("reasoning") {
    Some(True) => f["reasoning"] = Json::boolean(true)
    Some(False) => f["reasoning"] = Json::boolean(false)
    _ => ()
  }
  if strings_or(r.get("efforts")) is Some(v) {
    f["efforts"] = v
  }
  if cost_number(r.get("context")) is Some(n) {
    f["context"] = Json::number(n)
  }
  if cost_number(r.get("output")) is Some(n) {
    f["output"] = Json::number(n)
  }
  if r.get("cost") is Some(Object(c)) {
    match (cost_number(c.get("input")), cost_number(c.get("output"))) {
      (Some(i), Some(o)) => {
        let cost : Map[String, Json] = {
          "input": Json::number(i),
          "output": Json::number(o),
        }
        if cost_number(c.get("cacheRead")) is Some(n) {
          cost["cacheRead"] = Json::number(n)
        }
        if cost_number(c.get("cacheWrite")) is Some(n) {
          cost["cacheWrite"] = Json::number(n)
        }
        f["cost"] = Json::object(cost)
      }
      _ => ()
    }
  }
  Some(Json::object(f))
}

///|
/// Takes the catalog's `models` (as GET /v1/models answers them) in place of what it said before; how many it named.
pub fn Catalog::learn(self : Catalog, models : Json?) -> Int {
  let next : Map[String, Json] = Map([])
  if models is Some(Object(m)) {
    for id, raw in m {
      if facts_of(raw) is Some(f) {
        next[@readops.model_key(id)] = f
      }
    }
  }
  self.told = next
  self.version += 1
  next.length()
}

///|
/// The current catalog and its change counter (`catalog`).
pub fn Catalog::snapshot(self : Catalog) -> Json {
  { "version": Json::number(self.version.to_double()), "models": Json::object(self.told.copy()) }
}

///|
/// The keys of the models the catalog names.
pub fn Catalog::named(self : Catalog) -> Array[String] {
  self.told.keys().collect()
}

///|
/// What the catalog says of a model, however a profile spells it (anthropic/claude-opus-5-5[1m] is claude-opus-5-5,
/// gemini-4-hydrogen-high falls back to gemini-4-hydrogen); none for one it does not name.
pub fn Catalog::facts(self : Catalog, model : String) -> Json? {
  let key = @readops.model_key(model)
  let at = index_of(key, "[")
  let bare = if at >= 0 { sub(key, 0, at) } else { key }
  match self.told.get(bare) {
    Some(f) => Some(f)
    None =>
      match @readops.split_agy_tier(bare) {
        Some(m) => self.told.get(m)
        None => None
      }
  }
}
