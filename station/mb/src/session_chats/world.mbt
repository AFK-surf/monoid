// What the station is to these parts (src/sessions' `hub`, its store, its chats' surfaces, the actors, and the other
// parts of the station these call: the hub's tools' arguments, the readers, the files, the other stations): asked by
// name, `store.getSession`, `chat.post`, `actor.need`, `dep.stateArg`..., with its arguments as the TypeScript gives
// them, answered as it answers (a value, or what it threw). The program's own station gives its own; the harness asks
// the test, which answers from the same hub the TypeScript runs against. A function given as an argument (a check run
// inside a write, a listener) is a callback the station may call back while it is asked (`World::callback`).

///|
pub(all) struct World {
  /// Asks the station `name` with `args`; what it threw raises `Thrown(kind, message)`.
  call : async (String, Array[J]) -> J
  /// A callback the station may call back with its arguments while asked: what stands for it in an argument.
  callback : (async (Array[J]) -> J) -> J
  /// The station's words, and its own language (`stationLang`).
  words : Words
  lang : Ref[String]
  /// What the last error the station threw carried besides its words (its own fields: a `CcSessionsUnavailable`'s
  /// `sessions`...).
  thrown : Ref[J]
}

///|
/// Whether an answer is `undefined` (said `{"$u": 1}`).
pub fn is_undefined(v : J) -> Bool {
  match v {
    Obj([(k, Num(_))]) => @jsjson.sanitize_str(k) == "$u"
    _ => false
  }
}

///|
/// What the station answers, undefined as null (where the TypeScript does not tell them apart).
pub async fn World::ask(self : World, name : String, args : Array[J]) -> J {
  let v = (self.call)(name, args)
  if is_undefined(v) {
    Null
  } else {
    v
  }
}

///|
/// What the station answers, None where it is undefined (an index not ready yet, `...IfReady`).
pub async fn World::ask_u(self : World, name : String, args : Array[J]) -> J? {
  let v = (self.call)(name, args)
  if is_undefined(v) {
    None
  } else {
    Some(v)
  }
}

///|
/// A function the station gave (`{"$fn": id}`: the call `peersOf` gives, ...) called with `args`.
pub async fn World::call_fn(self : World, f : J, args : Array[J]) -> J {
  self.ask("fn.call", [f, ..args])
}

///|
pub fn World::tr(self : World, key : String, args? : Array[(String, String)] = []) -> String {
  self.words.tr(self.lang.val, key, args~)
}

///|
/// `hub.store.<name>(...args)`.
pub async fn World::store(self : World, name : String, args : Array[J]) -> J {
  self.ask("store." + name, args)
}

///|
pub async fn World::store_u(self : World, name : String, args : Array[J]) -> J? {
  self.ask_u("store." + name, args)
}

///|
/// Whether the hub has `name` (`hub.<name> != null`: a reader it may not have).
pub async fn World::has(self : World, name : String) -> Bool {
  self.ask("hub.has", [js(name)]) is Bool(true)
}

///|
/// Whether the store has `name` (a method a store from before lacks).
pub async fn World::store_has(self : World, name : String) -> Bool {
  self.ask("hub.storeHas", [js(name)]) is Bool(true)
}

///|
/// `hub.<name>(...args)`.
pub async fn World::hub(self : World, name : String, args : Array[J]) -> J {
  self.ask("hub." + name, args)
}

///|
/// What another part of the station does (src/sessions/args.ts, src/sessions/others.ts, the readers...): `dep.<name>`.
pub async fn World::dep(self : World, name : String, args : Array[J]) -> J {
  self.ask("dep." + name, args)
}

///|
/// `hub.chat(connect).<method>(...args)`.
pub async fn World::chat(self : World, connect : String, method : String, args : Array[J]) -> J {
  self.ask("chat." + method, [js(connect), ..args])
}

///|
/// `hub.actors.get(key)?.<method>(...args)` (null where it has no actor).
pub async fn World::actor(self : World, key : String, method : String, args : Array[J]) -> J {
  self.ask("actor." + method, [js(key), ..args])
}

///|
/// Whether session `key` has an actor (`hub.actors.get(key) !== undefined`).
pub async fn World::has_actor(self : World, key : String) -> Bool {
  self.ask("hub.hasActor", [js(key)]) is Bool(true)
}

///|
/// What the hub holds for its own (its held posts, the openings of relayed chats...): `state.<name>`.
pub async fn World::state(self : World, name : String, args : Array[J]) -> J {
  self.ask("state." + name, args)
}

///|
/// The station's clock, in ms (`hub.now()`).
pub async fn World::now(self : World) -> Double {
  num_of(Some(self.ask("hub.now", []))).unwrap_or(0.0)
}

///|
/// Waits `ms` of the wall's time (`wall.sleep`).
pub async fn World::sleep(self : World, ms : Double) -> Unit {
  self.ask("wall.sleep", [jn(ms)]) |> ignore
}

///|
/// The hub's config (`hub.config()`).
pub async fn World::config(self : World) -> J {
  self.ask("hub.config", [])
}

///|
/// Logged as the station logs (`log.warn`, `log.info`): its part, its words, its fields.
pub async fn World::log(self : World, level : String, part : String, words : String, fields : J) -> Unit {
  self.ask("log." + level, [js(part), js(words), fields]) |> ignore
}
