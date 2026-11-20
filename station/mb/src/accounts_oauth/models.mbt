// station/src/accounts/models.ts: what the station knows of models: which read images, and which are outdated: those
// a profile names in config.json (by hand, or ticked on before every model a profile's check found ran) that a newer
// model of their line, offered on the same profile, replaces once each.

///|
/// A model's key and its context ([1m]) apart.
fn split_context(model : String) -> (String, String) {
  let k = @readops.model_key(model)
  let at = index_of(k, "[")
  if at >= 0 {
    (sub(k, 0, at), from(k, at))
  } else {
    (k, "")
  }
}

///|
fn all_digits(s : String, least : Int) -> Bool {
  if s.length() < least {
    return false
  }
  for i in 0..<s.length() {
    if !is_ascii_digit(s.unsafe_charcode_at(i)) {
      return false
    }
  }
  true
}

///|
/// A model's line and its version in it, from its key: the words of its name without their numbers, and those numbers
/// (claude-fable-5-1 is claude-fable 5.1, claude-3-5-sonnet claude-sonnet 3.5, gpt-6.1-sol gpt-sol 6.1, kimi-k3 kimi-k
/// 3). A snapshot's stamp at its end is neither, so a snapshot is not newer than the model it pins.
pub fn line_of(model : String) -> (String, Array[Double]) {
  let words = split(split_context(model).0, "-")
  while words.length() > 1 && all_digits(words[words.length() - 1], 4) {
    ignore(words.pop())
  }
  let version : Array[Double] = []
  let named = []
  for w in words {
    // /[0-9]+(\.[0-9]+)*/g taken out, each number of it kept
    let out = StringBuilder()
    let n = w.length()
    let mut i = 0
    while i < n {
      if is_ascii_digit(w.unsafe_charcode_at(i)) {
        let mut j = i
        let mut value = 0.0
        while true {
          value = 0.0
          while j < n && is_ascii_digit(w.unsafe_charcode_at(j)) {
            value = value * 10.0 + (w.unsafe_charcode_at(j) - '0').to_double()
            j += 1
          }
          version.push(value)
          if j + 1 < n && w.unsafe_charcode_at(j) == '.' && is_ascii_digit(w.unsafe_charcode_at(j + 1)) {
            j += 1
            continue
          }
          break
        }
        i = j
        continue
      }
      out.write_char(w.unsafe_charcode_at(i).unsafe_to_char())
      i += 1
    }
    let left = out.to_string()
    if left != "" {
      named.push(left)
    }
  }
  (named.join("-"), version)
}

///|
/// Whether version `a` comes after `b` (5.1 after 5, 5.2 after 5.1).
fn version_after(a : Array[Double], b : Array[Double]) -> Bool {
  let n = if a.length() > b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    if i >= a.length() {
      return false
    }
    if i >= b.length() {
      return true
    }
    if a[i] != b[i] {
      return a[i] > b[i]
    }
  }
  false
}

///|
/// The newest model of `model`'s line among `offered`, if one is newer than it, in `model`'s context.
pub fn newer_of(model : String, offered : Array[String]) -> String? {
  let context = split_context(model).1
  let (line, version) = line_of(model)
  let mut best : (String, Array[Double])? = None
  for o in offered {
    let (of_line, of_version) = line_of(o)
    if of_line != line || !version_after(of_version, version) {
      continue
    }
    if best is Some((_, bv)) && !version_after(of_version, bv) {
      continue
    }
    best = Some((o, of_version))
  }
  match best {
    None => None
    Some((spelled, _)) =>
      Some(if split_context(spelled).1 == "" { spelled + context } else { spelled })
  }
}

///|
/// Models that read images, by key: each checked with a drawn digit, and its opposite, on OpenCode Go (2026-10-27).
pub let vision : Array[String] = [
  "deepseek-v4.1-flash", "glm-5.3-flash", "kimi-k3", "omen-alpha", "qwen3.8-flash",
]

///|
/// Families whose every model reads images.
let vision_families : Array[String] = ["claude-"]

///|
/// Whether a model takes image input, however a profile spells it: checked here, or its maker says so (the catalog).
pub fn sees_images(catalog : Catalog, model : String) -> Bool {
  let key = split_context(model).0
  if vision.contains(key) || vision_families.iter().any(f => key.has_prefix(f)) {
    return true
  }
  match get(catalog.facts(model), "input") {
    Some(Array(a)) => a.iter().any(v => v is String("image"))
    _ => false
  }
}

///|
/// agents/agy.ts `agyBaseModel` and agents/devin.ts `devinFusionBase`.
pub using @agent_runtimes {agy_base_model, devin_fusion_base}

///|
/// What unchecking changed on a profile.
pub(all) struct Unchecked {
  profile : String
  removed : Array[String]
  added : Array[String]
}

///|
pub fn Unchecked::to_json(self : Unchecked) -> Json {
  { "profile": Json::string(self.profile), "removed": jstrings(self.removed), "added": jstrings(self.added) }
}

///|
/// Unchecks, in config.json as parsed (`raw`, changed in place), the models a profile names that are outdated there,
/// each once: those its keys are not in `done`. One a newer model of its line replaces (`newer_of`), among those the
/// profile's check found (`found`) and those it names, gives its place to it; one a subscription's check found the
/// account no longer runs is unchecked, unless the profile would be left with no model. The profile's own default
/// (`model`) and a connect's (`bind.model`) naming one unchecked follow it to what replaced it. What changed, and the
/// keys unchecked (in the order they were). Copies of other stations' profiles are theirs to change.
pub fn uncheck_outdated(
  raw : Json,
  found : (String) -> Array[String]?,
  done : Array[String],
) -> (Array[Unchecked], Array[String]) {
  let changes = []
  let unchecked : Array[String] = []
  let replaced : Map[String, String?] = Map([])
  let profiles = match get(Some(raw), "profiles") {
    Some(Array(a)) => a
    _ => []
  }
  for pj in profiles {
    guard pj is Object(p) else { continue }
    guard p.get("models") is Some(Array(listed_models)) else { continue }
    if p.get("share") is Some(Object(share)) && share.get("borrowed") is Some(True) {
      continue
    }
    let models = strings_of(Some(Json::array(listed_models)))
    let id = js_string(p.get("id"))
    let listed = found(id)
    let offered = (match listed { Some(l) => l; None => [] }) + models
    let listed_keys = (match listed { Some(l) => l; None => [] }).map(m => split_context(m).0)
    let subscription = match p.get("access") {
      Some(Object(a)) => a.get("kind") is Some(String("subscription"))
      _ => false
    }
    let runtime = str_of(p.get("runtime"))
    let mut next = models.copy()
    let removed = []
    let added = []
    let keys = []
    let swaps : Map[String, String?] = Map([])
    for m in models {
      let key = split_context(m).0
      if done.contains(key) {
        continue
      }
      let agy_base = if runtime == Some("agy") { Some(agy_base_model(m).0) } else { None }
      let devin_base = if runtime == Some("devin") { Some(devin_fusion_base(m).0) } else { None }
      let newer = match (agy_base, devin_base) {
        (Some(b), _) if b != m && offered.contains(b) => Some(b)
        (_, Some(b)) if b != m && offered.contains(b) => Some(b)
        _ => newer_of(m, offered)
      }
      match newer {
        Some(n) => {
          let n_key = @readops.model_key(n)
          if !next.iter().any(o => o != m && @readops.model_key(o) == n_key) {
            next.push(n)
            added.push(n)
          }
        }
        None => {
          let gone = subscription &&
            (match listed {
              Some(l) => l.length() > 0
              None => false
            }) &&
            !listed_keys.contains(key)
          if !gone {
            continue
          }
        }
      }
      next = next.filter(o => o != m)
      removed.push(m)
      keys.push(key)
      swaps[m] = newer
    }
    if removed.length() == 0 || next.length() == 0 {
      continue
    }
    p["models"] = jstrings(next)
    for k in keys {
      if !unchecked.contains(k) {
        unchecked.push(k)
      }
    }
    for m, n in swaps {
      replaced[m] = n
    }
    if p.get("model") is Some(String(current)) && swaps.get(current) is Some(newer) {
      match newer {
        Some(n) => p["model"] = Json::string(n)
        None => p.remove("model")
      }
    }
    changes.push({ profile: id, removed, added })
  }
  match get(Some(raw), "connects") {
    Some(Array(connects)) =>
      for c in connects {
        if get(Some(c), "bind") is Some(Object(bind)) &&
          bind.get("model") is Some(String(model)) &&
          replaced.get(model) is Some(Some(n)) {
          bind["model"] = Json::string(n)
        }
      }
    _ => ()
  }
  (changes, unchecked)
}
