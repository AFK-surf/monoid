// What the station is to these parts where its other parts are asked (the hub and its store, a chat's card, the events
// a device is told, the tasks' transport, the devices' forwards): asked by name, `store.getSession`, `dep.postCard`,
// `remote.ask`..., with its arguments as the TypeScript gives them, answered as it answers: a value (undefined said
// `{"$u": 1}`), or what it threw (`Thrown(kind, message)`, a refusal of the mesh `Refused`). A function given as an
// argument (a card made again from the one it was, a write done inside another) is a callback the station may call back
// while it is asked (`World::callback`), at once: a write runs inside the station's own transaction, so it never waits
// on anything. The program's own station gives its parts; the harness asks the test, which
// answers from the same fakes the TypeScript runs against.

///|
pub(all) struct World {
  call : async (String, Array[Json]) -> Json
  callback : ((Array[Json]) -> Json raise) -> Json
}

///|
/// Whether an answer is `undefined`.
pub fn is_undefined(v : Json) -> Bool {
  v is Object(m) && m.length() == 1 && m.get("$u") is Some(_)
}

///|
/// `undefined`, as it is said.
pub fn undefined_json() -> Json {
  jobj([("$u", jnum(1.0))])
}

///|
/// What the station answers, undefined as None.
pub async fn World::ask(self : World, name : String, args : Array[Json]) -> Json? {
  let v = (self.call)(name, args)
  if is_undefined(v) {
    None
  } else {
    Some(v)
  }
}
