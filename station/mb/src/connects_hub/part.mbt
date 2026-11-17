// A chat platform's connects as a part of the agents' side (connects/part.ts; Slack's, Feishu's, the group connect's):
// connected while the station is in their workspace, once the sessions are taken up (a socket's event goes to one
// connection of an app; two processes' would split them), and disconnected as it leaves; their chats the hub takes and
// posts to; the names the pages show of their people and chats, looked up as they are heard of (who wrote, and where)
// and, as a connect connects, of the threads people read lately; how its kind of connect shows, is edited and is
// connected again (the agents' `connectKind`); the overview and the sidebar told as they change. Stopped before the
// agents hand their sessions over: the platform's events go to the next process from then on.

///|
/// What the part is given of the station besides the connects (`Store`, `Readers`, `Events`).
pub struct PartDeps {
  cards : Cards
  /// `readers.read("recentConnectPeople", {connect, limit: 200}, "zh")`: JSON, `[{thread, people}]`.
  recent_people : async (String) -> String
  overview_changed : () -> Unit
  /// `events.rowsChanged(null)`.
  rows_changed : () -> Unit
  log : Log
}

///|
/// What a platform's part says of its kind of connect (`KindOf`).
pub struct KindOf {
  /// config.json's `kind` of its connects.
  kind : String
  /// What a connect is known by in the overview, and its kind's own fields (ConnectKind `shown`).
  shown : (Connects, J) -> J
  /// What it does once its connects are in line with the config as the station takes its sessions up.
  taken : ((Connects) -> Unit)?
}

///|
pub struct Part {
  connects : Connects
  priv deps : PartDeps
  priv own : KindOf
  /// The connects whose recent people were looked up as they connected, once each.
  priv learned : Set[String]
}

///|
/// The part over `connects`: told of the connects' changes (the recent people of one connected, the overview).
pub fn connects_part(deps : PartDeps, connects : Connects, own : KindOf) -> Part {
  let p : Part = { connects, deps, own, learned: Set([]) }
  // A connect connected: the threads people read lately, learned once.
  ignore(connects.on_change(() => {
    for c in connects.connects() {
      let id = js_text(at(Some(c), "id"))
      if p.learned.contains(id) {
        continue
      }
      match connects.state(js(id)) {
        Some(s) if str_of(at(Some(s), "state")) == Some("connected") => ()
        _ => continue
      }
      p.learned.add(id)
      // Read by a reader: it goes through the station's threads by when they were said.
      spawn(async fn() {
        try {
          let text = (deps.recent_people)(id)
          for t in arr_of(Some(parse_js(text))).unwrap_or([]) {
            p.learn(num_of(at(Some(t), "thread")).unwrap_or(0.0), arr_of(at(Some(t), "people")).unwrap_or([]).map(x => js_text(Some(x))))
          }
        } catch {
          e => deps.log.warn(own.kind, "the people of a connect's recent chats not learned", jo([("connect", js(id)), ("error", js(thrown_message(e)))]))
        }
      })
    }
  }))
  // The sidebar names connects and their workspaces.
  ignore(connects.on_change(() => {
    (deps.overview_changed)()
    (deps.rows_changed)()
  }))
  p
}

///|
/// The names the pages show of people and chats are the readers' (from the names book); a connection looks up those
/// it does not know yet as it hears of them. A thread is its connect's: the one its sessions are of.
pub async fn Part::learn(self : Part, thread : Double, people : Array[String]) -> Unit {
  let t = (self.deps.cards.get_thread)(thread)
  if t is Null {
    return
  }
  let connect = (self.deps.cards.thread_sessions)(thread).map(m => js_text(at(Some(m), "connect"))).iter().find_first(c => c != internal_connect)
  guard connect is Some(connect) && self.connects.chat(connect) is Some(chat) else { return }
  if (chat.surface.has)("knownChannel") {
    ignore((chat.surface.get)("knownChannel", [at(Some(t), "channel").unwrap_or(undefined())]))
  }
  for user in people {
    if (chat.surface.has)("knownPerson") {
      ignore((chat.surface.get)("knownPerson", [js(user)]))
    }
  }
}

///|
/// A change of the store: the people of a thread's new messages learned, and the cards it ended changed where their
/// platform shows them.
pub async fn Part::store_changed(self : Part, change : J) -> Unit {
  if str_of(at(Some(change), "type")) != Some("thread") {
    return
  }
  let people : Array[String] = []
  for e in arr_of(at(Some(change), "entries")).unwrap_or([]) {
    if str_of(at(Some(e), "authorKind")) == Some("person") {
      let a = js_text(at(Some(e), "author"))
      if !people.contains(a) {
        people.push(a)
      }
    }
  }
  self.learn(num_of(at(Some(change), "id")).unwrap_or(0.0), people)
  // A card that stopped waiting changes where its platform shows it.
  show_ended(self.deps.cards, connect => self.connects.chat(connect).map(c => c.surface), change, self.deps.log)
}

///|
/// A connect's link to its platform now (ConnectKind `connection`).
pub fn Part::connection(self : Part, c : J) -> J {
  let id = match at(Some(c), "id") {
    Some(Null) | None => ""
    v => js_text(v)
  }
  self.connects.state(js(id)).unwrap_or(Null)
}

///|
/// What a connect is known by and its kind's own fields (ConnectKind `shown`).
pub fn Part::shown(self : Part, c : J) -> J {
  (self.own.shown)(self.connects, c)
}

///|
/// Connected again, and who its bot is read again (ConnectKind `reconnect`).
pub async fn Part::reconnect(self : Part, id : String) -> Unit {
  self.connects.reconcile()
  self.connects.refresh_identity(id) catch {
    e => self.deps.log.warn(self.own.kind, "who the bot is not read again", jo([("connect", js(id)), ("error", js(thrown_message(e)))]))
  }
}

///|
/// The sessions taken up: in line with the config.
pub async fn Part::taken(self : Part) -> Unit {
  self.connects.reconcile()
  match self.own.taken {
    Some(f) => f(self.connects)
    None => ()
  }
}

///|
/// A workspace joined, or the workspaces changed: those of a workspace left disconnect, those of one back connect.
pub async fn Part::changed(self : Part) -> Unit {
  self.connects.reconcile()
}

///|
/// The station left its workspace.
pub async fn Part::left(self : Part) -> Unit {
  self.connects.stop_all()
}
