// The station's parts that are modules of it, in its own process (station/src/parts.ts `StationParts`): each made by
// `run` (the composition root) and saying here what it adds to what the station answers: its routes of the admin API,
// the writes a read-only member may make of them, its own kinds of request on a member's link, its options cards, its
// fields of the overview, its tools for the agents, its places on the agents' door, what it does as a session ends or
// a member connects, and what it carries over a handover. Nothing registers itself: a part is in the station because
// `run` makes it. What is said here is read as it is asked for (a request, an agent's tool list), so what was made
// before the parts takes what they add. A request, a member and a card are JSON here, as the TypeScript's are objects.

///|
/// A part's route of the admin API: its method and path (a pattern as api/admin.ts's), answered from the request.
pub(all) struct PartRoute {
  meth : String
  path : String
  answer : async (Json) -> Json
}

///|
/// A part's tool for the agents (tools/mcp.ts `Tool`): its declaration (`name`, `description`, `inputSchema`) and its
/// call, given its arguments and the call's context (the session it is of).
pub(all) struct PartTool {
  name : String
  declared : Json
  call : async (Json, Json) -> Json
}

///|
/// A part's place on the agents' door (tools/http.ts): the requests under `/<prefix>/`, from programs on this machine
/// only; None where it wrote its answer on the connection itself.
pub(all) struct DoorRoute {
  prefix : String
  request : async (Request, Json) -> Reply?
}

///|
/// What a part says of its own kind of options card: whether a member (`viewer`) may choose on it (why not, else None),
/// and what is done once they did. `at`: where the card is (its thread, its entry's n and ts).
pub(all) struct CardChoice {
  may : (Json, Json, Json) -> String?
  chosen : (Json, Json, String, Json) -> Unit
}

///|
pub(all) suberror PartTwice {
  PartTwice(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for PartTwice with output(self, logger) {
  match self {
    PartTwice(m) => logger.write_string(m)
  }
}

///|
priv enum Routes {
  Made(Array[PartRoute])
  /// Made with what the admin API's routes are given (its readers, the store, the events).
  Of((Json) -> Array[PartRoute])
}

///|
priv struct Carried {
  give : async () -> Json
  take : (Json) -> Unit
}

///|
pub struct StationParts {
  priv cards : Array[(String, CardChoice)]
  priv routes : Array[Routes]
  priv viewer_may : Array[(String, String) -> Bool]
  priv overview : Array[(String, async (Json, String) -> Json)]
  priv tools : Array[(PartTool, (() -> Bool)?)]
  priv door : Array[DoorRoute]
  priv ended : Array[(String) -> Unit]
  priv streams : Array[(String, async (Json) -> Unit)]
  priv connected : Array[() -> Unit]
  priv carries : Map[String, Carried]
  /// What the process before carried over, for a part not made yet when it came.
  priv came : Map[String, Json]
  priv mut door_url : String?
}

///|
pub fn StationParts::new() -> StationParts {
  {
    cards: [],
    routes: [],
    viewer_may: [],
    overview: [],
    tools: [],
    door: [],
    ended: [],
    streams: [],
    connected: [],
    carries: Map([]),
    came: Map([]),
    door_url: None,
  }
}

// ── what the parts say ──

///|
/// A part's routes of the admin API (after the platform's own).
pub fn StationParts::routes(self : StationParts, routes : Array[PartRoute]) -> Unit {
  self.routes.push(Made(routes))
}

///|
/// A part's routes of the admin API, made with what the admin API's routes are given.
pub fn StationParts::routes_of(self : StationParts, make : (Json) -> Array[PartRoute]) -> Unit {
  self.routes.push(Of(make))
}

///|
/// A kind of request on a member's link a part answers itself: one whose head line has an object under `key`.
pub fn StationParts::streams(self : StationParts, key : String, answer : async (Json) -> Unit) -> Unit raise PartTwice {
  if self.streams.iter().any(s => s.0 == key) {
    raise PartTwice("a member's \{key} requests are answered twice")
  }
  self.streams.push((key, answer))
}

///|
/// A part's own kind of options card (`{"<key>": {…}}` beside its options).
pub fn StationParts::card_choice(self : StationParts, key : String, choice : CardChoice) -> Unit raise PartTwice {
  if self.cards.iter().any(c => c.0 == key) {
    raise PartTwice("a \{key} card's choice is taken twice")
  }
  self.cards.push((key, choice))
}

///|
/// Which of a part's requests besides reads a read-only member may make (method, path).
pub fn StationParts::viewer_may(self : StationParts, may : (String, String) -> Bool) -> Unit {
  self.viewer_may.push(may)
}

///|
/// A field of the overview, as a member (`viewer`) sees it in their language.
pub fn StationParts::overview(self : StationParts, field : String, view : async (Json, String) -> Json) -> Unit raise PartTwice {
  if self.overview.iter().any(o => o.0 == field) {
    raise PartTwice("the overview's \{field} is said twice")
  }
  self.overview.push((field, view))
}

///|
/// A part's tools for the agents; `offered`: while it says so (a `beta` feature's), else neither listed nor called.
pub fn StationParts::tools(self : StationParts, tools : Array[PartTool], offered? : () -> Bool) -> Unit {
  for t in tools {
    self.tools.push((t, offered))
  }
}

///|
/// A part's routes on the agents' door.
pub fn StationParts::door(self : StationParts, route : DoorRoute) -> Unit {
  self.door.push(route)
}

///|
/// What a part does when a session is archived or deleted.
pub fn StationParts::session_ended(self : StationParts, ended : (String) -> Unit) -> Unit {
  self.ended.push(ended)
}

///|
/// What a part does when a member's device connects.
pub fn StationParts::member_connected(self : StationParts, connected : () -> Unit) -> Unit {
  self.connected.push(connected)
}

///|
/// What a part holds only in memory and carries over to the next process at a handover: `give` it as this one hands
/// over, `take` what the one before gave (at once, where it came before the part was made).
pub fn StationParts::carry(self : StationParts, name : String, give : async () -> Json, take : (Json) -> Unit) -> Unit raise PartTwice {
  if self.carries.contains(name) {
    raise PartTwice("\{name} is carried over twice")
  }
  self.carries[name] = { give, take }
  match self.came.get(name) {
    Some(what) => {
      self.came.remove(name)
      take(what)
    }
    None => ()
  }
}

// ── what is asked of them ──

///|
fn is_object(v : Json?) -> Bool {
  v is Some(Object(_))
}

///|
/// The part whose card `card` is, if one.
pub fn StationParts::card_choice_of(self : StationParts, card : Json) -> CardChoice? {
  for c in self.cards {
    if card is Object(m) && is_object(m.get(c.0)) {
      return Some(c.1)
    }
  }
  None
}

///|
/// The part whose card `card` is, by the key it said its cards by (`card_choice`), if one.
pub fn StationParts::card_key_of(self : StationParts, card : Json) -> String? {
  for c in self.cards {
    if card is Object(m) && is_object(m.get(c.0)) {
      return Some(c.0)
    }
  }
  None
}

///|
/// The card choice a part said by `key`.
pub fn StationParts::card_choice_named(self : StationParts, key : String) -> CardChoice? {
  for c in self.cards {
    if c.0 == key {
      return Some(c.1)
    }
  }
  None
}

///|
/// What the parts carry over to the next process, by part (one that fails to give is left out).
pub async fn StationParts::carried(self : StationParts) -> Map[String, Json] {
  let out : Map[String, Json] = Map([])
  for name, part in self.carries {
    match (try { Ok((part.give)()) } catch { e => Err(e) }) {
      Ok(v) => out[name] = v
      Err(e) => err_write("station: a part's memory is not carried over (\{name}: \{e})\n")
    }
  }
  out
}

///|
/// What the process before carried over, to its parts (kept for one not made yet).
pub fn StationParts::take_up(self : StationParts, what : Map[String, Json]) -> Unit {
  for name, value in what {
    match self.carries.get(name) {
      Some(part) => (part.take)(value)
      None => self.came[name] = value
    }
  }
}

///|
/// A member's device connected.
pub fn StationParts::connected(self : StationParts) -> Unit {
  for c in self.connected {
    c()
  }
}

///|
pub fn StationParts::door_routes(self : StationParts) -> Array[DoorRoute] {
  self.door
}

///|
/// The part whose place on the door `path` is under (`/<prefix>/…` or `/<prefix>`), if one.
pub fn StationParts::door_route_of(self : StationParts, path : String) -> DoorRoute? {
  for d in self.door {
    if path == "/\{d.prefix}" || path.has_prefix("/\{d.prefix}/") {
      return Some(d)
    }
  }
  None
}

///|
/// Where agents reach the door now (`http://127.0.0.1:<port>/mcp`), once it is open.
pub fn StationParts::door_url(self : StationParts) -> String? {
  self.door_url
}

///|
pub fn StationParts::door_open(self : StationParts, url : String) -> Unit {
  self.door_url = Some(url)
}

///|
/// A session was archived or deleted.
pub fn StationParts::end_session(self : StationParts, session : String) -> Unit {
  for e in self.ended {
    e(session)
  }
}

///|
/// Every part's routes of the admin API, made with `tools`.
pub fn StationParts::all_routes(self : StationParts, tools : Json) -> Array[PartRoute] {
  let out = []
  for r in self.routes {
    match r {
      Made(rs) => out.push_iter(rs.iter())
      Of(make) => out.push_iter(make(tools).iter())
    }
  }
  out
}

///|
/// The part that answers a request whose head line is `head`, if one does.
pub fn StationParts::stream_of(self : StationParts, head : Json) -> (async (Json) -> Unit)? {
  for s in self.streams {
    if head is Object(m) && is_object(m.get(s.0)) {
      return Some(s.1)
    }
  }
  None
}

///|
/// Whether a read-only member may make this request.
pub fn StationParts::may_view(self : StationParts, meth : String, path : String) -> Bool {
  self.viewer_may.iter().any(may => may(meth, path))
}

///|
/// The parts' fields of the overview, as `viewer` sees them.
pub async fn StationParts::overview_of(self : StationParts, viewer : Json, lang : String) -> Map[String, Json] {
  let out : Map[String, Json] = Map([])
  for o in self.overview {
    out[o.0] = (o.1)(viewer, lang)
  }
  out
}

///|
/// The tools offered now.
pub fn StationParts::all_tools(self : StationParts) -> Array[PartTool] {
  self.tools.filter(t => t.1 is None || (t.1.unwrap())()).map(t => t.0)
}
