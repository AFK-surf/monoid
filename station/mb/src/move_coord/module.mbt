// A migration between two stations of a workspace is a set of independent modules and a scheduler that only orders
// them (station/src/move/module.ts; move/AGENTS.md): what each module would move (its items, each naming what it
// needs), each moved and moved back on its own, where each stands. An item and where it stands are kept as the
// TypeScript keeps them, JSON objects (`J`), their keys in the order that TypeScript sets them: what the scheduler
// writes of them (`last.json`) and says of them (a plan) is that TypeScript's. Every function a module gives is
// async: what it asks of its station may be another program's.

///|
/// What a move fails with, as the TypeScript's classes are told apart (`instanceof`): words for people (`Said`, and
/// `AskAgain` and `Gone`, which are `Said` too), the other station's refusal (mesh/bus.ts `Refused`), its connection
/// gone (mesh/peer.ts `PeerGone`, and `PeerStopped`, a `PeerGone` too), and any other error by its message.
pub(all) suberror MoveError {
  Said(String)
  AskAgain(String)
  Gone(String)
  Refused(String)
  PeerGone(String)
  PeerStopped(String)
  Failed(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for MoveError with output(self, logger) {
  match self {
    Said(m) | AskAgain(m) | Gone(m) | Refused(m) | PeerGone(m) | PeerStopped(m) | Failed(m) => logger.write_string(m)
  }
}

///|
pub fn message_of(e : Error) -> String {
  match e {
    Said(m) | AskAgain(m) | Gone(m) | Refused(m) | PeerGone(m) | PeerStopped(m) | Failed(m) =>
      m
    _ => e.to_string()
  }
}

///|
/// `e instanceof Said` (i18n.ts: AskAgain and Gone extend it).
pub fn is_said(e : Error) -> Bool {
  e is (Said(_) | AskAgain(_) | Gone(_))
}

///|
pub fn is_refused(e : Error) -> Bool {
  e is Refused(_)
}

///|
/// The kind a failure is told by across a program's edge (the harness's, a host's): its class's name.
pub fn kind_of(e : Error) -> String {
  match e {
    Said(_) => "Said"
    AskAgain(_) => "AskAgain"
    Gone(_) => "Gone"
    Refused(_) => "Refused"
    PeerGone(_) => "PeerGone"
    PeerStopped(_) => "PeerStopped"
    _ => "Error"
  }
}

///|
/// A failure of `kind` (`kind_of`), with its words.
pub fn error_of(kind : String, message : String) -> MoveError {
  match kind {
    "Said" => Said(message)
    "AskAgain" => AskAgain(message)
    "Gone" => Gone(message)
    "Refused" => Refused(message)
    "PeerGone" => PeerGone(message)
    "PeerStopped" => PeerStopped(message)
    _ => Failed(message)
  }
}

///|
/// What the station says, in its language (i18n.ts `tr(stationLang(), key, args)`), and what it logs (ops/log.ts).
pub(all) struct Say {
  words : (String, Array[(String, String)]) -> String
  /// The words in another language (`lang`: "zh", "en"): what a person's request is answered in.
  words_in : (String, String, Array[(String, String)]) -> String
  /// A line of the log: its level ("info", "warn"), its words, what it is of.
  logs : (String, String, J) -> Unit
}

///|
pub fn Say::of(
  tr_in : (String, String, Array[(String, String)]) -> String,
  lang : String,
  log? : (String, String, J) -> Unit = (_, _, _) => (),
) -> Say {
  { words: (k, a) => tr_in(lang, k, a), words_in: tr_in, logs: log }
}

///|
pub fn Say::tr(self : Say, key : String, args : Array[(String, String)]) -> String {
  (self.words)(key, args)
}

///|
pub fn Say::tr_in(self : Say, lang : String, key : String, args : Array[(String, String)]) -> String {
  (self.words_in)(lang, key, args)
}

///|
pub fn Say::log(self : Say, level : String, what : String, fields : J) -> Unit {
  (self.logs)(level, what, fields)
}

///|
/// An item a module's needs name, by its module and its id there.
pub(all) struct Need {
  module : String
  id : String
} derive(Eq, Hash)

///|
/// `named(n)`: `<module> <id>`.
pub fn Need::named(self : Need) -> String {
  "\{self.module} \{self.id}"
}

///|
pub fn Need::to_j(self : Need) -> J {
  jo([("module", js(self.module)), ("id", js(self.id))])
}

///|
pub fn need_of(j : J) -> Need {
  { module: text(get(Some(j), "module")).unwrap_or(""), id: text(get(Some(j), "id")).unwrap_or("") }
}

///|
/// What a stopped item waits for: the need, what people call it and the station it is on.
pub(all) struct Waits {
  module : String
  id : String
  label : String?
  at : String?
}

///|
pub fn Waits::need(self : Waits) -> Need {
  { module: self.module, id: self.id }
}

///|
pub fn Waits::to_j(self : Waits) -> J {
  let pairs = [("module", js(self.module)), ("id", js(self.id))]
  if self.label is Some(l) {
    pairs.push(("label", js(l)))
  }
  if self.at is Some(a) {
    pairs.push(("at", js(a)))
  }
  jo(pairs)
}

///|
pub fn waits_of(j : J) -> Waits {
  {
    module: text(get(Some(j), "module")).unwrap_or(""),
    id: text(get(Some(j), "id")).unwrap_or(""),
    label: text(get(Some(j), "label")),
    at: text(get(Some(j), "at")),
  }
}

// ── an item (module.ts `Item`), a JSON object: module, id, label, needs, cannot?, again?, size?, leaves? ──

///|
pub fn item_module(x : J) -> String {
  text(get(Some(x), "module")).unwrap_or("")
}

///|
pub fn item_id(x : J) -> String {
  text(get(Some(x), "id")).unwrap_or("")
}

///|
pub fn item_label(x : J) -> String {
  text(get(Some(x), "label")).unwrap_or("")
}

///|
pub fn item_need(x : J) -> Need {
  { module: item_module(x), id: item_id(x) }
}

///|
pub fn item_named(x : J) -> String {
  "\{item_module(x)} \{item_id(x)}"
}

///|
pub fn item_needs(x : J) -> Array[Need] {
  arr(get(Some(x), "needs")).unwrap_or([]).map(need_of)
}

///|
pub fn item_cannot(x : J) -> String? {
  text(get(Some(x), "cannot"))
}

///|
pub fn item_again(x : J) -> Bool {
  is_true(get(Some(x), "again"))
}

///|
/// An item of `module` and `id` with only its label (the scheduler's: what is kept stopped).
pub fn bare_item(module : String, id : String, needs : Array[Waits]) -> J {
  jo([
    ("module", js(module)),
    ("id", js(id)),
    ("label", js(id)),
    ("needs", ja(needs.map(w => w.to_j()))),
  ])
}

///|
/// An item as a module makes it.
pub fn new_item(
  module : String,
  id : String,
  label : String,
  needs : Array[Need],
  cannot? : String,
  again? : Bool = false,
  leaves? : String,
) -> J {
  let pairs = [
    ("module", js(module)),
    ("id", js(id)),
    ("label", js(label)),
    ("needs", ja(needs.map(n => n.to_j()))),
  ]
  if cannot is Some(c) {
    pairs.push(("cannot", js(c)))
  }
  if again {
    pairs.push(("again", jb(true)))
  }
  if leaves is Some(l) {
    pairs.push(("leaves", js(l)))
  }
  jo(pairs)
}

// ── where an item stands (module.ts `ItemState`), a JSON object: state, error?, progress?, waitsFor?, at?, waits?,
// from?, lentTo? ──

///|
pub fn state_name(st : J) -> String {
  text(get(Some(st), "state")).unwrap_or("here")
}

///|
pub fn st(state : String) -> J {
  jo([("state", js(state))])
}

///|
/// How far something is (`Progress`).
pub fn progress_j(done : Double, total : Double, unit : String) -> J {
  jo([("done", jn(done)), ("total", jn(total)), ("unit", js(unit))])
}

///|
/// What one plan reads once for all the modules that need it (module.ts `PlanReads`): the workspace's chats a page at
/// a time, and the canonical clones a directory's linked worktrees hang on.
pub(all) struct PlanReads {
  /// Each page, in order, read as it is first asked (`pages()`).
  pages : async (async (Page) -> Unit) -> Unit
  load : async () -> Unit
  loaded : () -> Array[Page]
  worktrees : async (String) -> Array[(String, String)]
}

///|
/// A page of sessions (store.ts `SessionPage`): its keys, its rows (each a session's row as the store gives it:
/// key, ws, title, workspace, connect, lastActiveAt, archivedAt…), a session's row by its key (one of the page's, or
/// one its home chat brings), and the host's own handle of it (what is given back to the host: handover.ts's reads).
pub(all) struct Page {
  keys : Array[String]
  rows : Array[J]
  session : async (String) -> J?
  handle : J
}

///|
/// The seam every module is (module.ts `Module`). What a module has not is None.
pub(all) struct Module {
  id : String
  needs : Array[String]
  plan : async (String, String, PlanReads?) -> Array[J]
  move : async (J, String, (J) -> Unit, Waits?) -> Unit
  back : async (J, String, Waits?) -> Unit
  state : async (J) -> J
  usable_here : (async (J) -> Bool)?
  usable_there : (async (J) -> Bool)?
  can_lend : (async (J) -> Bool)?
  lend : (async (J, String, Array[Need]) -> Unit)?
  lent_for : (async (J, String, Array[Need]) -> Unit)?
  left : (async (Array[Need]) -> Unit)?
  is_here : (async (J) -> Bool)?
  abandon : (() -> Unit)?
  ready : (async (J, String) -> String?)?
  stop : (async (J, Waits) -> Unit)?
  resume : (async (J) -> Unit)?
}

///|
/// What an item's failure says to people (module.ts `sayOf`): the station's words and the other station's refusal as
/// they are; anything else logged whole and said in the catalog's.
pub fn say_of(s : Say, e : Error, what : String) -> String {
  let message = message_of(e)
  if is_said(e) || is_refused(e) {
    return message
  }
  s.log(
    "warn",
    "an item failed: the error, said to people in the station's words",
    jo([("item", js(what)), ("error", js(message))]),
  )
  s.tr(
    if unanswered_words(message) {
      "station.move.why.unanswered"
    } else {
      "station.move.why.failedHere"
    },
    [],
  )
}

///|
/// What the transport says of a station that did not answer (module.ts `UNANSWERED`, case aside).
pub fn unanswered_words(message : String) -> Bool {
  let m = message.to_lower()
  if m.contains("answered nothing") ||
    m.contains("got no answer") ||
    m.contains("timed out") ||
    m.contains("station unreachable") {
    return true
  }
  for w in ["connection", "stream"] {
    let ends = if w == "connection" {
      ["gone", "lost", "closed", "reset"]
    } else {
      ["reset", "closed", "stopped"]
    }
    for e in ends {
      if m.contains("\{w} \{e}") || m.contains("\{w} was \{e}") {
        return true
      }
    }
  }
  false
}

///|
/// A plan's question of the other station not answered (module.ts `notAnswered`): said once in the log.
pub fn not_answered(s : Say, method : String, to : String, e : Error) -> Error {
  s.log(
    "warn",
    "a plan's question of the other station was not answered",
    jo([
      ("method", js(method)),
      ("station", js(slice_to(to, 12))),
      ("error", js(message_of(e))),
    ]),
  )
  e
}

///|
/// (module.ts `unanswered`)
pub fn unanswered(s : Say) -> String {
  s.tr("station.move.sched.unanswered", [])
}
