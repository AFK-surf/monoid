// What is not yet everyone's, as the core says it (client/core-ts/src/features.ts): the app keeps no registry and no
// rule of its own. The device's own features are the prefs' `features` (each on or off as the core worked it out of the
// channel and the switches), 设置 › 实验性功能 lists the prefs' `experimentalItems`, and a feature a station runs (its
// terminals, moving its things) is what that station's overview says (`features`): `station_feature`. Not said yet
// (the prefs not come, a station from before) is off.

///|
/// Experimental choices made on this device before `prefs.set` answers: shown at once, let go once the core says the same.
let experimental_chosen : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()

///|
fn features_reset() -> Unit {
  experimental_chosen.clear()
}

///|
/// Whether the device's own feature `id` is on, as the prefs' `features` say (and as a switch pressed here a moment ago).
pub fn feature_from(prefs : Json?, id : String) -> Bool {
  let said = field(field(prefs, "features"), id) is Some(True)
  match experimental_chosen.get(id) {
    Some(v) => {
      if v == said && prefs is Some(_) {
        experimental_chosen.remove(id)
      }
      v
    }
    None => said
  }
}

///|
/// The items of 设置 › 实验性功能 on this channel, in the core's order, each on or off (`experimentalItems`).
pub fn experimental_items_from(prefs : Json?) -> Array[(String, Bool)] {
  let out : Array[(String, Bool)] = []
  match field(prefs, "experimentalItems") {
    Some(Array(said)) =>
      for item in said {
        match field(Some(item), "id") {
          Some(String(id)) => out.push((id, feature_from(prefs, id)))
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
pub fn experimental_items(core : Core) -> Array[(String, Bool)] {
  experimental_items_from((core.topic)("prefs", Map([])).get().value)
}

///|
pub fn experimental_on(core : Core, id : String) -> Bool {
  feature_from((core.topic)("prefs", Map([])).get().value, id)
}

///|
/// Whether station `s` (a station as the core shapes it, its `overview` in it) runs its `beta` feature `id`: its own
/// channel decides, as its overview's `features` says.
pub fn station_feature(s : Json?, id : String) -> Bool {
  match field(field(s, "overview"), "features") {
    Some(Array(ids)) => {
      for x in ids {
        if x is String(i) && i == id {
          return true
        }
      }
      false
    }
    _ => false
  }
}

///|
/// Toggle experimental feature `id` on this device (`prefs.set {experimental: {<id>: true | null}}`), shown at once.
pub fn set_experimental(core : Core, id : String, on : Bool) -> Unit {
  experimental_chosen[id] = on
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
