// station_retire on this station (retire-asks.ts): an agent assists a station's retirement, and a person confirms it at
// its two moments, each with a card in the agent's chat (開始迁移, 暂停聊天并交接), counted only on the very entry the
// station posted for that ask, chosen in the app by an owner or admin of the workspace.

///|
pub let retire_off = "retiring a station is switched off for now: it is being fixed after its first use lost files; nothing was started"

///|
let asks_kept = 20

///|
fn option_key(kind : String) -> String {
  if kind == "start" {
    "station.retire.card.start"
  } else {
    "station.retire.card.handOver"
  }
}

///|
/// What RetireAsks is given (retire-asks.ts `AsksDeps`).
pub(all) struct AsksDeps {
  data : String
  here : () -> String?
  roster : (String) -> Array[Member]?
  /// The workspace a session's chat is of (its own, else the home one's).
  ws_of : async (String) -> String?
  /// A card posted in the session's chat (its thread and ts; None: not posted), and whether that card still waits
  /// there ("same"), another does ("other"), or none ("none").
  card_post : async (String, String, J) -> (Double, String)?
  card_state : async (String, Double, String) -> String
  /// The session's agent told something by the station (it wakes it; throws where there is none).
  notify : async (String, String) -> Unit
  now : () -> Double
  id : (() -> String)?
  starts : Bool
  manages : (J) -> Bool
}

///|
/// An ask a card confirms (retire-asks.ts `RetireAsk`), kept as JSON in its order.
pub struct RetireAsks {
  w : World
  d : AsksDeps
  retire : Retire
  mut asks : Array[J]
  mut writing : Run
  acting : Array[Run]
}

///|
fn asks_file(fs : Fs, data : String) -> String {
  fs.join([data, "replica", "retire-asks.json"])
}

///|
pub async fn RetireAsks::new(w : World, d : AsksDeps, retire : Retire) -> RetireAsks {
  let kept = match w.fs.read_json(asks_file(w.fs, d.data)) {
    Some(Arr(xs)) => xs
    _ => []
  }
  { w, d, retire, asks: kept, writing: Run::over(), acting: [] }
}

///|
fn last_asks(xs : Array[J]) -> Array[J] {
  if xs.length() > asks_kept {
    xs[xs.length() - asks_kept:].to_array()
  } else {
    xs
  }
}

///|
fn RetireAsks::save(self : RetireAsks) -> Run {
  let text = stringify(ja(last_asks(self.asks)))
  let before = self.writing
  let fs = self.w.fs
  let run = self.w.run(async fn() {
    before.settled()
    try {
      let path = asks_file(fs, self.d.data)
      fs.mkdirs(fs.dirname(path))
      // (a name of its own, as the other writes here: two at once each rename theirs; let go of where this fails)
      let tmp = "\{path}.\{fs.random_hex(4)}.tmp"
      errdefer @effect.uninterruptible(async fn() { fs.rm_f(tmp) catch { _ => () } })
      fs.write_text(tmp, text)
      fs.rename(tmp, path)
    } catch {
      e => self.w.warn("retire", "station_retire's asks not written", jo([("error", js(message_of(e)))]))
    }
  })
  self.writing = run
  run
}

///|
/// What is being taken and written, done.
pub async fn RetireAsks::settle(self : RetireAsks) -> Unit {
  while self.acting.length() > 0 {
    for r in self.acting.copy() {
      r.settled()
    }
  }
  self.writing.settled()
}

///|
/// Whether `session` here asked for `station`'s retirement and a person confirmed it.
pub fn RetireAsks::drives(self : RetireAsks, station : String, session : String) -> Bool {
  self.asks.iter().any(a => text_at(a, "station") == station &&
    text_at(a, "session") == session &&
    (text_at(a, "state") == "confirmed" || text_at(a, "state") == "done"))
}

///|
fn RetireAsks::index_of(self : RetireAsks, id : String) -> Int? {
  self.asks.search_by(a => text_at(a, "id") == id)
}

///|
pub fn RetireAsks::get(self : RetireAsks, id : String) -> J? {
  self.index_of(id).map(i => self.asks[i])
}

///|
fn RetireAsks::put(self : RetireAsks, a : J) -> Unit {
  match self.index_of(text_at(a, "id")) {
    Some(i) => self.asks[i] = a
    None => ()
  }
}

///|
pub fn RetireAsks::confirm_label(self : RetireAsks, kind : String) -> String {
  self.w.tr("\{option_key(kind)}.confirm")
}

///|
/// station_retire: what the agent of `session` asked, answered as data with what it says in words (`say`).
pub async fn RetireAsks::tool(self : RetireAsks, session : String, args : J) -> J {
  let action = match at(args, "action") {
    Some(Str(u)) => @jsjson.text(u)
    None | Some(Null) => ""
    Some(v) => stringify(v)
  }
  if !self.d.starts && (action == "start" || action == "hand_over") {
    raise refused(retire_off)
  }
  let ws = (self.d.ws_of)(session)
  let here = (self.d.here)()
  guard ws is Some(ws) && here is Some(here) else { raise refused("this chat is of no workspace: no station of it to retire") }
  let roster = (self.d.roster)(ws).unwrap_or([])
  let named = fn(v : J?, what : String) -> Member raise {
    let want = match v {
      Some(Str(u)) if js_trim(@jsjson.text(u)) != "" => js_trim(@jsjson.text(u))
      _ => raise refused("\{what} is needed: a station of this workspace, by its name or id (station_list)")
    }
    let found = roster.filter(r => r.id == want || r.name.to_lower() == want.to_lower() || (want.length() >= 8 && r.id.has_prefix(want)))
    if found.length() == 1 {
      return found[0]
    }
    if found.length() > 1 {
      raise refused("\{what} \{want} names \{found.length()} stations: give its id (station_list)")
    }
    if is_station(want) {
      return { id: want, name: "", tasks: false }
    }
    raise refused("\{what} \{want} is no station of this workspace (station_list lists them)")
  }
  let target = match at(args, "station") {
    None | Some(Str([])) =>
      {
        id: here,
        name: match roster.search_by(r => r.id == here) {
          Some(i) => roster[i].name
          None => ""
        },
        tasks: false,
      }
    v => named(v, "station")
  }
  let ask = async fn(request : Array[(String, J)]) -> J {
    if target.id == here {
      self.retire.agent_ask(ws, jo([..request, ("driver", jo([("station", js(here)), ("session", js(session))]))]))
    } else {
      self.w.ask(target.id, jo([("method", js("retire.ask")), ("workspace", js(ws)), ("session", js(session)), ..request])) catch {
        e => {
          if is_refused(e) && (message_of(e).contains("no such retire request") || message_of(e).contains("unknown")) {
            let who = if target.name != "" { target.name } else { head_of(target.id, 12) }
            raise refused("station \{who} is from before station_retire: update it first, or retire it from the app")
          }
          raise e
        }
      }
    }
  }
  let to_given = () => match at(args, "to") {
    None | Some(Str([])) => false
    _ => true
  }
  match action {
    "preview" => {
      let to = if to_given() { Some(named(at(args, "to"), "to")) } else { None }
      let r = ask([("op", js("preview")), ..(match to { Some(t) => [("to", js(t.id))]; None => [] })])
      merged(r, jo([("say", js(self.preview_words(r, match to { Some(t) => t.name; None => "" })))]))
    }
    "status" => {
      let r = ask([("op", js("status"))])
      merged(r, jo([("say", js(self.status_words(r)))]))
    }
    "start" => {
      let to = named(at(args, "to"), "to")
      if to.id == target.id {
        raise refused("the chats go to another station than the one retired")
      }
      let r = ask([("op", js("preview")), ("to", js(to.id))])
      match at(at(r, "status").unwrap_or(Null), "retiring") {
        Some(Null) | None => ()
        Some(s) => {
          let who = if target.name != "" { target.name } else { "it" }
          raise refused("station \{who} is being retired already (\{text_at(s, "step")}): station_retire status says where it stands")
        }
      }
      let ready = at(r, "to").unwrap_or(Null)
      let to_said = if to.name != "" { to.name } else { head_of(to.id, 12) }
      if at(ready, "reached") is Some(Bool(false)) {
        raise refused("station \{to_said} is not reached now (\{show_value(at(ready, "error"))}): start once it is up")
      }
      if at(ready, "old") is Some(Bool(true)) {
        raise refused("station \{to_said} is from before stations could be retired: update it first")
      }
      let text = self.start_card(target.name, to.name, r)
      let to_name = if to.name != "" { to.name } else { str_at(ready, "name").unwrap_or("") }
      self.asked(session, "start", ws, target.id, target.name, Some(to.id), to_name, text)
    }
    "hand_over" => {
      let r = ask([("op", js("status"))])
      let s = match at(at(r, "status").unwrap_or(Null), "retiring") {
        Some(Null) | None => {
          let who = if target.name != "" { target.name } else { "it" }
          raise refused("station \{who} is not being retired: station_retire start first")
        }
        Some(s) => s
      }
      if text_at(s, "step") != "sent" {
        raise refused(
          if text_at(s, "step") == "sending" {
            "the files are still being sent: you are told once they are all there"
          } else {
            "it is past that: \{text_at(s, "step")}"
          },
        )
      }
      self.asked(session, "hand_over", ws, target.id, target.name, str_at(s, "to"), text_at(s, "toName"), self.hand_over_card(target.name, s))
    }
    "again" => {
      let r = ask([("op", js("again"))])
      merged(r, jo([("say", js("Tried again now: you are told as it goes on."))]))
    }
    "cancel" => {
      let r = ask([("op", js("cancel"))])
      merged(r, jo([("say", js("Called off: the chats go on on the station they were on."))]))
    }
    _ => raise refused("action is one of preview, status, start, hand_over, again, cancel")
  }
}

///|
/// What JavaScript puts in a template for a value: `${v}`.
fn show_value(v : J?) -> String {
  match v {
    None => "undefined"
    Some(Null) => "null"
    Some(Str(u)) => @jsjson.text(u)
    Some(Num(n)) => num_text(n)
    Some(Bool(b)) => if b { "true" } else { "false" }
    Some(Arr(_) as a) => items(Some(a)).map(x => show_value(Some(x))).join(",")
    Some(Obj(_)) => "[object Object]"
  }
}

///|
/// A card asking a person to confirm `kind`, posted in the session's chat.
async fn RetireAsks::asked(
  self : RetireAsks,
  session : String,
  kind : String,
  ws : String,
  station : String,
  station_name : String,
  to : String?,
  to_name : String,
  text : String,
) -> J {
  let found = self.asks.search_by(x => text_at(x, "session") == session &&
    text_at(x, "kind") == kind &&
    text_at(x, "station") == station &&
    text_at(x, "state") == "asked" &&
    (kind != "start" || str_at(x, "to") == to))
  let mut a = found.map(i => self.asks[i])
  match a {
    Some(x) if !(at(x, "thread") is (Some(Null) | None)) && !(at(x, "ts") is (Some(Null) | None)) => {
      let place = (self.d.card_state)(session, num_at(x, "thread").unwrap_or(0.0), text_at(x, "ts"))
      if place == "same" {
        let confirm = str_at(x, "confirm").unwrap_or(self.confirm_label(kind))
        return jo([
          ("ask", at(x, "id").unwrap_or(Null)),
          ("card", js("waiting")),
          ("say", js("The card is in this chat already, waiting for an owner or admin of the workspace to choose \{confirm} in the still.fail app. You are told when they do.")),
        ])
      }
      if place == "other" {
        raise refused(card_occupied)
      }
    }
    _ => ()
  }
  // (another ask of this session's for the same station, of another kind or target, is let go of: one at a time)
  let same_id = match a {
    Some(x) => text_at(x, "id")
    None => ""
  }
  for i, x in self.asks {
    if text_at(x, "id") != same_id && text_at(x, "session") == session && text_at(x, "station") == station && text_at(x, "state") == "asked" {
      self.asks[i] = set(x, "state", js("dropped"))
    }
  }
  if a is None {
    let id = match self.d.id {
      Some(f) => f()
      None => "r_\{self.w.fs.random_hex(6)}"
    }
    let made = jo([
      ("kind", js(kind)),
      ("ws", js(ws)),
      ("station", js(station)),
      ("stationName", js(station_name)),
      ("to", jopt(to)),
      ("toName", js(to_name)),
      ("id", js(id)),
      ("session", js(session)),
      ("state", js("asked")),
      ("thread", Null),
      ("ts", Null),
      ("at", jn((self.d.now)())),
      ("by", Null),
      ("error", Null),
    ])
    self.asks.push(made)
    self.asks = last_asks(self.asks)
    a = Some(made)
  }
  guard a is Some(x) else { return Null }
  let id = text_at(x, "id")
  let k = option_key(kind)
  let confirm = self.w.tr("\{k}.confirm")
  let card = jo([
    ("type", js("options")),
    (
      "options",
      ja([
        jo([("label", js(confirm)), ("detail", js(self.w.tr("\{k}.confirmDetail"))), ("action", js("close")), ("recommended", jb(true))]),
        jo([("label", js(self.w.tr("\{k}.decline"))), ("detail", js(self.w.tr("station.retire.card.declineDetail"))), ("action", js("close"))]),
      ]),
    ),
    (
      "retire",
      jo([
        ("ask", js(id)),
        ("kind", js(kind)),
        ("station", js(station)),
        ("name", at(x, "stationName").unwrap_or(Null)),
        ("to", at(x, "to").unwrap_or(Null)),
        ("toName", at(x, "toName").unwrap_or(Null)),
      ]),
    ),
  ])
  // (no card of before counts once another is posted for the same ask)
  self.update(id, [("thread", Null), ("ts", Null)])
  let posted = (self.d.card_post)(session, text, card)
  self.update(id, [
    ("thread", match posted { Some(p) => jn(p.0); None => Null }),
    ("ts", match posted { Some(p) => js(p.1); None => Null }),
    ("confirm", js(confirm)),
  ])
  self.save().settled()
  jo([
    ("ask", js(id)),
    ("card", js("posted")),
    (
      "say",
      js("A card is in this chat: an owner or admin of the workspace confirms it (\{confirm}) in the still.fail app; nothing happens until then, and a message in the chat ends the card without deciding (ask again then). You are told what they chose."),
    ),
  ])
}

///|
pub let card_occupied = "Another card is pending in that conversation. Resolve or withdraw it before asking this again."

///|
fn RetireAsks::update(self : RetireAsks, id : String, fields : Array[(String, J)]) -> Unit {
  match self.index_of(id) {
    Some(i) => {
      let mut a = self.asks[i]
      for f in fields {
        a = set(a, f.0, f.1)
      }
      self.asks[i] = a
    }
    None => ()
  }
}

///|
/// The ask whose card is the entry at `at` (its thread and ts).
fn RetireAsks::ask_at(self : RetireAsks, card : J, thread : Double, ts : String) -> J? {
  let id = match at(card, "retire") {
    Some(r) => show_value(at(r, "ask").map(x => if x is Null { Str([]) } else { x }))
    None => ""
  }
  match self.get(if id == "undefined" { "" } else { id }) {
    Some(a) if num_at(a, "thread") == Some(thread) && str_at(a, "ts") == Some(ts) => Some(a)
    _ => None
  }
}

///|
/// Why `viewer` may not choose on this card at `at` (None: they may).
pub fn RetireAsks::may(self : RetireAsks, viewer : J, card : J, thread : Double, ts : String) -> String? {
  guard self.ask_at(card, thread, ts) is Some(a) else { return Some(self.w.tr("station.retire.askGone")) }
  if !(self.d.manages)(viewer) || str_at(viewer, "workspace") != Some(text_at(a, "ws")) {
    return Some(self.w.tr("station.retire.ownersOnly"))
  }
  None
}

///|
/// `viewer` chose `option` on the card at `at`: confirmed, the step is taken as them; declined, nothing.
pub fn RetireAsks::chosen(self : RetireAsks, viewer : J, card : J, option : String, thread : Double, ts : String) -> Unit {
  guard self.ask_at(card, thread, ts) is Some(a) && text_at(a, "state") == "asked" else { return }
  let id = text_at(a, "id")
  let station = text_at(a, "station")
  let name = if text_at(a, "stationName") != "" { text_at(a, "stationName") } else { head_of(station, 12) }
  let email = text_at(viewer, "email")
  let kind = text_at(a, "kind")
  let confirm = str_at(a, "confirm").unwrap_or(self.confirm_label(kind))
  if js_trim(option) != confirm {
    self.update(id, [("state", js("declined")), ("by", js(email))])
    ignore(self.save())
    let what = if kind == "start" { "retired" } else { "handed over" }
    self.tell_session(text_at(a, "session"), "\{email} chose \{js_trim(option)} on the card: station \{name} is not \{what}; nothing was done.")
    return
  }
  self.update(id, [("by", js(email))])
  if !self.d.starts {
    self.update(id, [("state", js("failed")), ("error", js(retire_off))])
    ignore(self.save())
    self.tell_session(text_at(a, "session"), "\{email} confirmed it in the app, but \{retire_off}.")
    return
  }
  self.update(id, [("state", js("confirmed"))])
  ignore(self.save())
  let mine : Ref[Run?] = Ref(None)
  let acting = self.w.run(async fn() {
    self.act(id, email) catch {
      _ => ()
    }
    match mine.val {
      Some(m) =>
        match self.acting.search_by(r => physical_equal(r, m)) {
          Some(i) => ignore(self.acting.remove(i))
          None => ()
        }
      None => ()
    }
  })
  mine.val = Some(acting)
  if !acting.is_done() {
    self.acting.push(acting)
  }
}

///|
async fn RetireAsks::act(self : RetireAsks, id : String, by : String) -> Unit {
  guard self.get(id) is Some(a) else { return }
  let here = (self.d.here)()
  let station = text_at(a, "station")
  let kind = text_at(a, "kind")
  let name = if text_at(a, "stationName") != "" { text_at(a, "stationName") } else { head_of(station, 12) }
  let request = if kind == "start" {
    [("op", js("start")), ("to", js(str_at(a, "to").unwrap_or(""))), ("by", js(by))]
  } else {
    [("op", js("hand_over")), ("by", js(by))]
  }
  let to_name = if text_at(a, "toName") != "" { text_at(a, "toName") } else { "the other station" }
  try {
    guard here is Some(here) else { raise failed("this station is not in its workspace now") }
    if station == here {
      ignore(self.retire.agent_ask(text_at(a, "ws"), jo([..request, ("driver", jo([("station", js(here)), ("session", at(a, "session").unwrap_or(Null))]))])))
    } else {
      ignore(self.w.ask(station, jo([("method", js("retire.ask")), ("workspace", at(a, "ws").unwrap_or(Null)), ("session", at(a, "session").unwrap_or(Null)), ..request])))
    }
    self.update(id, [("state", js("done"))])
    self.save().settled()
    self.tell_session(
      text_at(a, "session"),
      if kind == "start" {
        "\{by} confirmed it in the app: station \{name} is being retired, its chats going to \{to_name}. Its files are sent first while the chats work; you are told once they are all there, then call station_retire hand_over."
      } else {
        "\{by} confirmed the hand-over in the app: the chats of station \{name} stop now and go to \{to_name}; you are told when they are taken there, or if it fails."
      },
    )
  } catch {
    e => {
      self.update(id, [("state", js("failed")), ("error", js(message_of(e)))])
      self.save().settled()
      let did = if kind == "start" { "start" } else { "go" }
      self.tell_session(
        text_at(a, "session"),
        "\{by} confirmed it in the app, but it did not \{did}: \{message_of(e)}. Put that right, then call station_retire \{kind} again (a person confirms again).",
      )
    }
  }
}

///|
fn RetireAsks::tell_session(self : RetireAsks, session : String, text : String) -> Unit {
  self.w.go(async fn() {
    (self.d.notify)(session, text) catch {
      e => self.w.warn("retire", "station_retire's asker not told", jo([("session", js(session)), ("error", js(message_of(e)))]))
    }
  })
}

///|
fn RetireAsks::listed(self : RetireAsks, xs : Array[J]) -> String {
  xs.map(x => text_at(x, "name")).join(if self.w.lang.val == "en" { ", " } else { "、" })
}

///|
fn n_arg(v : J?) -> String {
  match v {
    Some(Num(n)) => num_text(n)
    None => "0"
    other => show_value(other)
  }
}

///|
/// Card one's words, from the preview.
fn RetireAsks::start_card(self : RetireAsks, name : String, to_name : String, r : J) -> String {
  let w = (key : String, args : Array[(String, String)]) => self.w.tr("station.retire.card.\{key}", args~)
  let p = at(r, "preview").unwrap_or(Obj([]))
  let to = at(r, "to").unwrap_or(Obj([]))
  let accounts = items(at(p, "accounts"))
  let stay = items(at(p, "accountsStay"))
  let archived = match at(p, "archived") {
    Some(Num(n)) if n != 0.0 => w("start.archived", [("n", num_text(n))])
    _ => ""
  }
  let outside = match at(p, "outside") {
    Some(Num(n)) if n != 0.0 => w("start.outside", [("n", num_text(n))])
    _ => ""
  }
  let lines = [
    w("start.title", [
      ("name", if name != "" { name } else { w("thisStation", []) }),
      ("to", if to_name != "" { to_name } else if text_at(to, "name") != "" { text_at(to, "name") } else { w("otherStation", []) }),
    ]),
    w("start.moves", [
      ("chats", n_arg(at(p, "chats"))),
      ("connects", items(at(p, "connects")).length().to_string()),
      ("archived", archived),
      (
        "accounts",
        if accounts.length() > 0 {
          w("start.accounts", [("n", accounts.length().to_string()), ("names", self.listed(accounts))])
        } else {
          ""
        },
      ),
    ]),
    w("start.stays", [
      ("outside", outside),
      ("accountsStay", if stay.length() > 0 { w("start.accountsStay", [("names", self.listed(stay))]) } else { "" }),
    ]),
  ]
  match at(to, "free") {
    Some(Num(free)) =>
      lines.push(w(if at(to, "git") is Some(Bool(false)) { "start.roomNoGit" } else { "start.room" }, [("free", gb(free))]))
    _ => ()
  }
  lines.push("\{w("start.next", [])}\{if self.w.lang.val == "en" { " " } else { "" }}\{w("owners", [])}")
  lines.join("\n\n")
}

///|
/// Card two's words: what was sent, and what confirming it does.
fn RetireAsks::hand_over_card(self : RetireAsks, name : String, s : J) -> String {
  let w = (key : String, args : Array[(String, String)]) => self.w.tr("station.retire.card.\{key}", args~)
  let minutes = match (at(s, "sentAt"), at(s, "at")) {
    (Some(Num(sent)), Some(Num(at))) => {
      let m = js_round((sent - at) / 60000.0)
      Some(if m > 0.0 { m } else { 0.0 })
    }
    _ => None
  }
  let names = [
    ("name", if name != "" { name } else { w("thisStation", []) }),
    ("to", if text_at(s, "toName") != "" { text_at(s, "toName") } else { w("otherStation", []) }),
  ]
  let size = match at(s, "total") {
    Some(Num(n)) => gb(n)
    _ => gb(0.0)
  }
  [
    w(if minutes is None { "handOver.sent" } else { "handOver.sentIn" }, [
      ..names,
      ("files", n_arg(at(s, "files"))),
      ("size", size),
      ("minutes", match minutes { Some(m) => num_text(m); None => "null" }),
    ]),
    w("handOver.what", names),
    w("owners", []),
  ].join("\n\n")
}

///|
let remove_words = "Taking the retired station out of the workspace is a person's own step in the still.fail app: the retired station's page (设置 → Stations → it) offers 移出工作区 once it is done."

///|
/// The preview, in words an agent acts on.
fn RetireAsks::preview_words(self : RetireAsks, r : J, to_name : String) -> String {
  let p = at(r, "preview").unwrap_or(Obj([]))
  let station = at(r, "station").unwrap_or(Obj([]))
  let who = if text_at(station, "name") != "" { text_at(station, "name") } else { "this one" }
  let accounts = items(at(p, "accounts"))
  let accounts_words = if accounts.length() > 0 { " and \{accounts.length()} accounts" } else { "" }
  let out = [
    "Station \{who} would move \{n_arg(at(p, "chats"))} chats (\{n_arg(at(p, "archived"))} archived besides), \{items(at(p, "connects")).length()} connects\{accounts_words}; running jobs (\{items(at(p, "jobs")).length()}) are started again there. \{n_arg(at(p, "outside"))} chats work in a directory that is not the station's own and stays.",
  ]
  let stay = items(at(p, "accountsStay"))
  if stay.length() > 0 {
    out.push("Accounts that stay (it is not its home workspace): \{self.listed(stay)}.")
  }
  match at(r, "to") {
    Some(Null) | None => ()
    Some(to) => {
      let that = if to_name != "" {
        to_name
      } else if text_at(to, "name") != "" {
        text_at(to, "name")
      } else {
        "That station"
      }
      if at(to, "reached") is Some(Bool(false)) {
        out.push("\{that} is not reached now: \{show_value(at(to, "error"))}.")
      } else if at(to, "old") is Some(Bool(true)) {
        out.push("\{that} is from before stations could be retired: update it first.")
      } else {
        let git = match at(to, "git") {
          Some(Bool(true)) => "is there"
          Some(Num(n)) if n != 0.0 => "is there"
          Some(Str(u)) if u.length() > 0 => "is there"
          _ => "is NOT there (worktrees cannot be made again: install it first)"
        }
        let free = match at(to, "free") {
          Some(Num(f)) => "\{gb(f)} free (what is sent is known once sending starts; it needs about as much again, twice where its disk makes no clones)"
          _ => "its free room is not known"
        }
        out.push("\{that} is reached; git \{git}; \{free}.")
      }
    }
  }
  match at(at(r, "status").unwrap_or(Null), "retiring") {
    Some(Null) | None => ()
    Some(s) => out.push("It is being retired already: \{show_value(at(s, "step"))}.")
  }
  out.push(
    "Not moved by anything: tools installed on the machine, and config.json's machine settings (sandboxes, agentEnv). Check them on the target with station_task before start.",
  )
  out.join(" ")
}

///|
fn jobs_words(jobs : Array[J]) -> String {
  jobs
  .map(j => {
    let started = match at(j, "started") {
      Some(Bool(true)) => true
      _ => false
    }
    let why = match at(j, "why") {
      Some(Null) | None => "from a station before jobs moved"
      v => show_value(v)
    }
    "\{show_value(at(j, "name"))} \{if started { "started again" } else { "not started (\{why})" }}"
  })
  .join("; ")
}

///|
/// Where a retirement stands, in words an agent acts on.
fn RetireAsks::status_words(_self : RetireAsks, r : J) -> String {
  let status = at(r, "status").unwrap_or(Null)
  let out = []
  match at(status, "retiring") {
    Some(Null) | None => {
      let station = at(r, "station").unwrap_or(Obj([]))
      let who = if text_at(station, "name") != "" { text_at(station, "name") } else { "this one" }
      out.push("Station \{who} is not being retired.")
    }
    Some(s) => {
      let error_given = match at(s, "error") {
        Some(Null) | None | Some(Str([])) | Some(Bool(false)) => false
        Some(Num(n)) => n != 0.0
        _ => true
      }
      let num = (k : String) => match at(s, k) {
        Some(Num(n)) => n
        _ => 0.0
      }
      let step = text_at(s, "step")
      let to_name = if text_at(s, "toName") != "" { text_at(s, "toName") } else { "the other station" }
      let said = match step {
        "sending" => "sending its files (\{gb(num("done"))} of \{gb(num("total"))}) while the chats work"
        "sent" =>
          if error_given {
            "back at sent: the chats work again here after the hand-over failed (\{show_value(at(s, "reason"))}: \{show_value(at(s, "error"))}); call hand_over again once that is put right"
          } else {
            "all of it sent; waiting for the hand-over to be confirmed (hand_over)"
          }
        "quiet" => "the chats stopped; what changed is being sent"
        "handing" => "\{to_name} is putting the chats in (it restarts for it)"
        "accounts" => "taken there; its accounts move"
        "connects" => "taken there; its connects move"
        "done" => "done"
        other => other
      }
      let whom = if text_at(s, "toName") != "" { text_at(s, "toName") } else { show_value(at(s, "to")) }
      out.push("Retiring to \{whom}: \{said}.")
      if error_given && step != "sent" {
        let again = if at(s, "retriable") is Some(Bool(true)) { " (it tries again by itself; again tries it now)" } else { "" }
        out.push("Last failure (\{show_value(at(s, "reason"))}): \{show_value(at(s, "error"))}\{again}.")
      }
      let there = items(at(s, "jobsThere"))
      if there.length() > 0 {
        out.push("Jobs there: \{jobs_words(there)}.")
      }
      let left = items(at(s, "accountsLeft"))
      if left.length() > 0 {
        out.push("Accounts left on the retired station: \{left.map(a => "\{show_value(at(a, "name"))}: \{show_value(at(a, "error"))}").join("; ")}.")
      }
      if step == "done" {
        out.push(remove_words)
      }
    }
  }
  for t in items(at(status, "taking")) {
    let who = if text_at(t, "name") != "" { text_at(t, "name") } else { show_value(at(t, "origin")) }
    let err = match at(t, "error") {
      Some(Null) | None | Some(Str([])) => ""
      v => " (\{show_value(v)})"
    }
    out.push("Taking the chats of \{who}: \{show_value(at(t, "step"))}\{err}.")
  }
  for t in items(at(status, "taken")) {
    let who = if text_at(t, "name") != "" { text_at(t, "name") } else { show_value(at(t, "origin")) }
    let but = match at(t, "error") {
      Some(Str(u)) if u.length() > 0 => " but \{@jsjson.text(u)};"
      _ => ""
    }
    let jobs = items(at(t, "jobs"))
    out.push(
      "This station took the chats of station \{who} (\{show_value(at(t, "chats"))} chats) and is that station too now;\{but} jobs: \{if jobs.length() == 0 { "none" } else { jobs_words(jobs) }}. Its accounts and connects follow as it finishes. \{remove_words}",
    )
  }
  out.join(" ")
}
