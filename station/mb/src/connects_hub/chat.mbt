// A chat surface as these parts use one (sessions/chat.ts `ChatSurface`), and a connect's live link to its platform
// (connects/connections.ts `Connection`). A surface's calls are asked by their TypeScript names, as another station's
// chat asks them of a connect here (remote.mbt `answer_call`), its arguments and answer as JSON: `has` says which of
// the optional ones it has (the hub tells a call it does not have by its absence), `get` answers those that answer at
// once (its bot, its platform, a name already known), `call` any of them.

///|
pub(all) struct Surface {
  /// Whether it has the call `name` (`typeof surface[name] === "function"`; `cards`, `loginCards` whether they are
  /// true).
  has : (String) -> Bool
  /// What a call that answers at once answers (`botUserId`, `botName`, `identity`, `platform`, `mention`,
  /// `workspace`, `cards`, `loginCards`, `sessionLink`, `answerFiles`, `knownPerson`, `knownChannel`, `working`,
  /// `standsAt`); undefined (`{"$u": 1}`) where it has none.
  get : (String, Array[J]) -> J
  /// Any call by its name, waited on.
  call : async (String, Array[J]) -> J
  /// Whether it is another station's connect as the hub here uses it (remote.mbt `RemoteSurface`).
  remote : Bool
}

///|
/// undefined, as the wire says it.
pub fn undefined() -> J {
  jo([("$u", jn(1.0))])
}

///|
/// Its bot's user id (`botUserId()`).
pub fn Surface::bot_user_id(self : Surface) -> String {
  str_of(Some((self.get)("botUserId", []))).unwrap_or("")
}

///|
/// A call that answers at once, by name, where it has it (`surface.name?.(...)`): None where it has none.
pub fn Surface::get_opt(self : Surface, name : String, args : Array[J]) -> J? {
  if !(self.has)(name) {
    return None
  }
  let v = (self.get)(name, args)
  if is_undefined(v) {
    None
  } else {
    Some(v)
  }
}

///|
/// A live chat connection (connections.ts `Connection`): a surface, and how its link stands.
pub(all) struct Connection {
  surface : Surface
  /// Starts receiving: what the platform says (a `ChatEvent`) handed on, resolving once it is kept.
  start : async (async (J) -> Unit) -> Unit
  stop : async () -> Unit
  /// Whether the platform's socket is up, and the last connection error: `{connected, lastError}`.
  socket : () -> J
  /// Who its bot is and where (a `BotIdentity`), null before it knows.
  identity : () -> J
  /// Hears whenever `socket` or `identity` changes; gives the function that stops it.
  on_change : (() -> Unit) -> () -> Unit
  /// Reads again who the bot is and where; listeners hear of it.
  refresh_identity : async () -> Unit
}

///|
/// An identity as the pages are given it (without its bot id): `shownIdentity`.
pub fn shown_identity(i : J) -> J {
  jo([
    ("team", at(Some(i), "team").unwrap_or(undefined())),
    ("teamId", at(Some(i), "teamId").unwrap_or(undefined())),
    ("url", at(Some(i), "url").unwrap_or(undefined())),
    ("botUserId", at(Some(i), "botUserId").unwrap_or(undefined())),
    ("botName", at(Some(i), "botName").unwrap_or(undefined())),
    ("botImage", at(Some(i), "botImage").unwrap_or(undefined())),
  ])
  |> drop_undefined
}

///|
/// A value with its undefined fields left out, as `JSON.stringify` leaves them.
pub fn drop_undefined(v : J) -> J {
  match v {
    Obj(fs) => Obj(fs.filter(f => !is_undefined(f.1)).map(f => (f.0, drop_undefined(f.1))))
    Arr(xs) => Arr(xs.map(x => if is_undefined(x) { J::Null } else { drop_undefined(x) }))
    other => other
  }
}

///|
/// A list of listeners, each heard in the order added (a `Set` of them).
pub struct Listeners {
  priv items : Map[Int, () -> Unit]
  priv mut next : Int
}

///|
pub fn Listeners::new() -> Listeners {
  { items: {}, next: 0 }
}

///|
/// Adds one; gives the function that takes it out again.
pub fn Listeners::add(self : Listeners, f : () -> Unit) -> () -> Unit {
  self.next += 1
  let id = self.next
  self.items[id] = f
  () => self.items.remove(id)
}

///|
/// Each told, in order; what raises... none raises (MoonBit's listeners are `() -> Unit`).
pub fn Listeners::tell(self : Listeners) -> Unit {
  for f in self.items.values().to_array() {
    f()
  }
}

///|
pub fn Listeners::clear(self : Listeners) -> Unit {
  self.items.clear()
}
