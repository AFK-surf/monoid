// Feature registry and per-device experimental switches in MoonBit, kept identical to client/core-ts/src/features.ts by
// scripts/features-check.ts. `beta` features follow `testChannel` (on in beta, hidden in stable); `experimental`
// features are off by default on both channels and toggled in 设置 › 实验性功能 (`beta_only` hides the switch on stable).

///|
/// Each registered feature: `(id, stage, beta_only)` in declaration order.
// kept across runs: a value (never changed)
let feature_registry : Array[(String, String, Bool)] = [
  ("chatPage", "experimental", false),
  ("farviewNative", "experimental", false),
  ("board", "experimental", false),
  ("terminal", "beta", false),
  ("stationMove", "beta", false),
]

///|
/// Optimistic experimental choices made on this device before `prefs.set` answers.
let experimental_chosen : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()

///|
fn features_reset() -> Unit {
  experimental_chosen.clear()
}

///|
/// Whether `prefs` comes from the test channel (`beta`); true when no `testChannel` field is present (made-up fixtures
/// and traces recorded before the field existed).
pub fn test_channel_from(prefs : Json?) -> Bool {
  match field(prefs, "testChannel") {
    Some(False) => false
    _ => true
  }
}

///|
/// Whether experimental switch `id` is turned on on this device, reconciling `experimental_chosen` with `prefs`.
pub fn experimental_from(prefs : Json?, id : String) -> Bool {
  let exp = field(prefs, "experimental")
  let kept = match field(exp, id) {
    Some(True) => true
    Some(False) => false
    _ => id == "chatPage" && pref_from(prefs, "chatPage") == "nodes"
  }
  match experimental_chosen.get(id) {
    Some(v) => {
      if v == kept && prefs is Some(_) {
        experimental_chosen.remove(id)
      }
      v
    }
    None => kept
  }
}

///|
/// Whether feature `id` is effectively enabled given `prefs` (and any optimistic switch press here).
pub fn feature_from(prefs : Json?, id : String) -> Bool {
  for entry in feature_registry {
    if entry.0 == id {
      if entry.1 == "beta" {
        return match field(field(prefs, "features"), id) {
          Some(True) => true
          Some(False) => false
          _ => test_channel_from(prefs)
        }
      }
      if entry.2 && !test_channel_from(prefs) {
        return false
      }
      return experimental_from(prefs, id)
    }
  }
  false
}

///|
/// Visible `(id, enabled)` items for 设置 › 实验性功能 on this channel, in registry order.
pub fn experimental_items_from(prefs : Json?) -> Array[(String, Bool)] {
  // (as the core says them, where it does: features.ts experimentalItemsOf; each shown as chosen here meanwhile)
  match field(prefs, "experimentalItems") {
    Some(Array(said)) => {
      let out : Array[(String, Bool)] = []
      for item in said {
        match field(Some(item), "id") {
          Some(String(id)) => out.push((id, experimental_from(prefs, id)))
          _ => ()
        }
      }
      return out
    }
    _ => ()
  }
  let beta = test_channel_from(prefs)
  let out : Array[(String, Bool)] = []
  for entry in feature_registry {
    if entry.1 == "experimental" && (!entry.2 || beta) {
      out.push((entry.0, experimental_from(prefs, entry.0)))
    }
  }
  out
}

///|
pub fn experimental_items(core : Core) -> Array[(String, Bool)] {
  experimental_items_from((core.topic)("prefs", Map([])).get().value)
}

///|
pub fn experimental_on(core : Core, id : String) -> Bool {
  experimental_from((core.topic)("prefs", Map([])).get().value, id)
}

///|
/// Toggle experimental feature `id` on this device (`prefs.set {experimental: {<id>: true | null}}`), shown at once.
pub fn set_experimental(core : Core, id : String, on : Bool) -> Unit {
  experimental_chosen[id] = on
  if id == "chatPage" {
    chosen.remove("chatPage")
  }
  (core.call)(
    "prefs.set",
    obj([("experimental", obj([(id, if on { Json::boolean(true) } else { Json::null() })]))]),
    fn(r) {
      match r {
        Ok(_) => ()
        Err(e) => {
          experimental_chosen.remove(id)
          (core.say)(
            fill("android-misc.act.failed", [("what", tr("web-pages.experimental.title")), ("error", error_text(e))]),
          )
        }
      }
    },
  )
}

///|
/// Every registered feature's state given the channel and the switches on (`features`, as the core's features.ts
/// `featuresOf` says it): a made-up core's.
pub fn features_json(test_channel : Bool, on : Map[String, Bool]) -> Json {
  let out : Map[String, Json] = Map([])
  for entry in feature_registry {
    let (id, stage, beta_only) = entry
    out[id] = Json::boolean(
      if stage == "beta" {
        test_channel
      } else {
        (!beta_only || test_channel) && on.get(id) == Some(true)
      },
    )
  }
  Json::object(out)
}

///|
/// The items 实验性功能 shows on the channel (`experimentalItems`, as features.ts `experimentalItemsOf`): a made-up
/// core's.
pub fn experimental_items_json(test_channel : Bool, on : Map[String, Bool]) -> Json {
  let out : Array[Json] = []
  for entry in feature_registry {
    let (id, stage, beta_only) = entry
    if stage == "experimental" && (!beta_only || test_channel) {
      out.push({ "id": Json::string(id), "enabled": Json::boolean(on.get(id) == Some(true)) })
    }
  }
  Json::array(out)
}

///|
/// The switches on, as the prefs' `experimental` keeps them (only those registered as experimental): a made-up core's.
pub fn experimental_json(on : Map[String, Bool]) -> Json {
  let out : Map[String, Json] = Map([])
  for entry in feature_registry {
    if entry.1 == "experimental" && on.get(entry.0) == Some(true) {
      out[entry.0] = Json::boolean(true)
    }
  }
  Json::object(out)
}
