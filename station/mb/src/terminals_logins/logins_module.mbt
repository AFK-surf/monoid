// station/src/logins/module.ts: the station's logins to command-line tools as a part of the station: each told on the
// event streams as it changes, its screen followed by the pages; one an agent started tells that agent as it asks
// something and as it ends, its cards closed. Its routes (machine-logins) and the agents' `login` tool. A login on
// another station of the workspace (the tool's `station`) is that station's, asked over the station transport
// (`login.call`); it tells the agent here as it asks something and as it ends (`login.told`).

///|
/// What another station is refused with over the transport (mesh/bus.ts Refused).
pub(all) suberror BusRefused {
  BusRefused(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for BusRefused with output(self, logger) {
  match self {
    BusRefused(m) => logger.write_string(m)
  }
}

///|
/// What the logins' part asks of the station's other parts.
pub(all) struct LoginsHost {
  /// The store: a session's workspace, its row (who made it, its workspace), the login cards it closes (their
  /// sessions).
  session_ws : (String) -> String?
  session_row : (String) -> (String?, String?)?
  close_login_cards : (String) -> Array[String] raise
  /// events.machineLogins({login}, {login: limited}, key).
  machine_logins : (J, J, String) -> Unit
  /// hub.notify(session, text).
  notify : (String, String) -> Unit raise
  /// The chat's name as the chat list calls it (sessions/messages.ts `sender`'s first).
  chat_title : (String) -> String? raise
  /// readers.names: a person's name by their email.
  name_of : (String) -> String?
  /// This station and its workspace (`place()`).
  place : () -> (String, String)?
  /// Where a person's client opens a login (`pages()`: origin, workspace, station).
  page_base : () -> (String, String, String)?
  /// peer-http.ts `nameOf(cloud, id)`, `peerNamed(cloud, name).id` (raises where none is named so).
  station_name : (String) -> String
  peer_named : (String) -> String raise
  /// bus.ask(station, request): what it answers; raises BusRefused with what it was refused for.
  ask : async (String, J) -> J
  spawn : (async () -> Unit) -> Unit
  log : (String, J) -> Unit
}

///|
/// encodeURIComponent.
pub fn encode_uri_component(s : String) -> String {
  let out = StringBuilder::new()
  let keep = (c : Int) => (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
    (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
    (c >= '0'.to_int() && c <= '9'.to_int()) ||
    "-_.!~*'()".contains_char(Int::unsafe_to_char(c))
  let hex = "0123456789ABCDEF"
  for b in utf8_of(s) {
    let c = b.to_int()
    if c < 0x80 && keep(c) {
      out.write_char(Int::unsafe_to_char(c))
    } else {
      out.write_char('%')
      out.write_char(hex.get_char(c >> 4).unwrap())
      out.write_char(hex.get_char(c & 15).unwrap())
    }
  }
  out.to_string()
}

///|
pub struct LoginsPart {
  logins : Logins
  priv host : LoginsHost
  /// The logins whose agent was told they ask something (once a time they do).
  priv asking : Map[String, Bool]
}

///|
/// The part made on `logins`: what it tells as they change and end.
pub fn LoginsPart::new(logins : Logins, host : LoginsHost) -> LoginsPart {
  let part = { logins, host, asking: {} }
  logins.changes(id => part.changed(id)) |> ignore
  logins.on_ended((login, starter) => part.ended(login, starter)) |> ignore
  part
}

///|
/// A login's link in a person's client (`session`'s workspace where it has one).
pub fn LoginsPart::link(self : LoginsPart, session : String?, id : String) -> String? {
  guard (self.host.page_base)() is Some((origin, workspace, station)) else { return None }
  let ws = match session {
    Some(s) =>
      match (self.host.session_ws)(s) {
        Some(w) => w
        None => workspace
      }
    None => workspace
  }
  Some("\{origin}/w/\{ws}/s/\{station}/login/\{encode_uri_component(id)}")
}

///|
/// This station as an agent on another one is told of a login here.
pub fn LoginsPart::here(self : LoginsPart) -> Where {
  let id = match (self.host.place)() {
    Some((station, _)) => station
    None => ""
  }
  { station: id, name: (self.host.station_name)(id) }
}

///|
/// What a login another station's agent started tells it (its session there): as it asks something, as it ends.
fn LoginsPart::tell_peer(self : LoginsPart, starter : Starter, id : String, text : String, ended : Bool) -> Unit {
  guard starter.peer is Some((station, session)) else { return }
  let request = jo([
    ("method", js("login.told")),
    (
      "workspace",
      match starter.workspace {
        Some(w) => js(w)
        None => Null
      },
    ),
    ("session", js(session)),
    ("login", js(id)),
    ("ended", jb(ended)),
    ("text", js(text)),
  ])
  (self.host.spawn)(async fn() {
    (self.host.ask)(station, request) |> ignore catch {
      error =>
        (self.host.log)(
          "another station's agent was not told of its login",
          jo([("login", js(id)), ("station", js(station)), ("error", js(bus_message(error)))]),
        )
    }
  })
}

///|
fn bus_message(e : Error) -> String {
  match e {
    BusRefused(m) => m
    _ => error_message(e)
  }
}

///|
fn LoginsPart::changed(self : LoginsPart, id : String) -> Unit {
  guard self.logins.get(id) is Some(login) else { return }
  let l = Some(login)
  (self.host.machine_logins)(jo([("login", login)]), jo([("login", limited(login))]), "login\u{0}" + id)
  // Asking something again after its person's browser step (az picking a subscription, say): its agent answers. An
  // agent whose call waits on it is told by that call.
  let asks = get(l, "waiting") is Some(Bool(true)) &&
    !(get(l, "paste") is Some(Bool(true))) &&
    get(l, "endedAt") is None &&
    self.logins.had_browser_step(id)
  let tell = asks && !self.asking.contains(id) && !self.logins.heard(id)
  match text(get(l, "chat")) {
    Some(chat) if tell && chat != "" =>
      (self.host.notify)(chat, prompt_notice(self.logins, login, self.link(Some(chat), id))) catch {
        error =>
          (self.host.log)(
            "an agent was not told its login asks something",
            jo([("login", js(id)), ("error", js(error_message(error)))]),
          )
      }
    _ => ()
  }
  match self.logins.starter_of(id) {
    Some(starter) if tell && starter.peer is Some(_) =>
      self.tell_peer(starter, id, prompt_notice(self.logins, login, self.link(None, id), where_=self.here()), false)
    _ => ()
  }
  if asks {
    self.asking[id] = true
  } else {
    self.asking.remove(id)
  }
}

///|
/// Told: the agent that started it, and each that posted its card (one may post a card for a login under way).
fn LoginsPart::ended(self : LoginsPart, login : J, starter : Starter) -> Unit {
  let id = text(get(Some(login), "id")).unwrap_or("")
  // Another station's agent started it: told there, where its cards are.
  if starter.peer is Some(_) {
    return self.tell_peer(starter, id, ended_notice(login, self.link(None, id), where_=self.here()), true)
  }
  let carded = (self.host.close_login_cards)(id) catch {
    error => {
      (self.host.log)("a login's cards were not closed", jo([("login", js(id)), ("error", js(error_message(error)))]))
      []
    }
  }
  let sessions : Array[String] = []
  match starter.chat {
    Some(c) if c != "" => sessions.push(c)
    _ => ()
  }
  for s in carded {
    if !sessions.contains(s) {
      sessions.push(s)
    }
  }
  for session in sessions {
    (self.host.notify)(session, ended_notice(login, self.link(Some(session), id))) catch {
      error =>
        (self.host.log)(
          "an agent was not told a login ended",
          jo([("login", js(id)), ("session", js(session)), ("error", js(error_message(error)))]),
        )
    }
  }
}

///|
/// A Slack login card: shown only for a login waiting for a code from its page or entered on a device code's page,
/// that page and the device code on it.
pub fn LoginsPart::slack_card(self : LoginsPart, id : String) -> J? {
  match self.logins.get(id) {
    Some(login) => slack_page(login)
    None => None
  }
}

///|
/// Its field handed to the login (hub.logins.answer: what it raised let go, as `void` did).
pub fn LoginsPart::slack_answer(self : LoginsPart, id : String, code : String, by : Person) -> Unit raise Refused {
  self.logins.answer(id, Some(js(code)), by~) |> ignore
}

///|
/// The chat's starter: whom the agent works for.
pub fn LoginsPart::starter_of(self : LoginsPart, session : String) -> Starter {
  let row = (self.host.session_row)(session)
  let email = match row {
    Some((Some(e), _)) => e
    _ => ""
  }
  let mut chat_title = (self.host.chat_title)(session) catch { _ => None }
  if chat_title == Some(session) {
    chat_title = None
  }
  let workspace = match row {
    Some((_, Some(w))) => Some(w)
    _ =>
      match (self.host.place)() {
        Some((_, w)) => Some(w)
        None => None
      }
  }
  {
    by: { email, name: (self.host.name_of)(email).unwrap_or("") },
    workspace,
    chat: Some(session),
    chat_title,
    peer: None,
  }
}

///|
/// Another station's agent logging this one in (`login.call`), and a login of this station's agents on another one
/// telling them of it (`login.told`): what `peer` asked, over `workspace`.
pub async fn LoginsPart::heard_peer(self : LoginsPart, peer : String, request : J, workspace : J) -> J {
  let r = Some(request)
  match text(get(r, "method")) {
    Some("login.call") => {
      let args = match get(r, "args") {
        Some(Obj(_) as a) => a
        Some(Arr(_) as a) => a
        _ => jo([])
      }
      let session = text(get(r, "session")).unwrap_or("")
      let by = match get(r, "by") {
        Some(b) if text(get(Some(b), "email")) is Some(email) =>
          {
            email,
            name: match get(Some(b), "name") {
              None | Some(Null) => ""
              Some(n) => js_string_of(n)
            },
          }
        _ => { email: "", name: "" }
      }
      let chat_title = text(get(r, "chatTitle"))
      let ws = match workspace {
        Str(u) => Some(@jsjson.raw_text(u))
        _ => None
      }
      let starter = () => { by, workspace: ws, chat: None, chat_title, peer: Some((peer, session)) }
      let answer = act(self.logins, args, {
        starter,
        link: id => self.link(None, id),
        where_: Some(self.here()),
        mine: Some(id => match self.logins.starter_of(id) {
          Some({ peer: Some((station, _)), .. }) => station == peer
          _ => false
        }),
      }) catch {
        error => raise BusRefused(error_message(error))
      }
      jo([("text", js(answer))])
    }
    Some("login.told") => {
      let session = text(get(r, "session")).unwrap_or("")
      guard (self.host.session_row)(session) is Some(_) && text(get(r, "text")) is Some(told_text) else {
        raise BusRefused("no such session")
      }
      if get(r, "ended") is Some(Bool(true)) && text(get(r, "login")) is Some(login) {
        ignore((self.host.close_login_cards)(login)) catch {
          error =>
            (self.host.log)(
              "a login's cards were not closed",
              jo([("login", js(login)), ("error", js(error_message(error)))]),
            )
        }
      }
      (self.host.notify)(session, told_text)
      jo([])
    }
    _ =>
      raise BusRefused(
        "unknown method " +
        (match get(r, "method") {
          Some(m) => js_string_of(m)
          None => "undefined"
        }),
      )
  }
}

///|
/// The agents' `login` tool on this station: a login on another one asked of it over the transport.
pub fn LoginsPart::tool(self : LoginsPart) -> LoginToolDeps {
  {
    logins: () => Some(self.logins),
    starter: session => self.starter_of(session),
    link: (session, id) => self.link(Some(session), id),
    remote: Some(async fn(station, session, args) {
      let id = (self.host.peer_named)(station)
      let starter = self.starter_of(session)
      let rest = match args {
        Obj(ps) => J::Obj(ps.filter(p => p.0 != @jsjson.units("station")))
        other => other
      }
      let request = jo([
        ("method", js("login.call")),
        (
          "workspace",
          match starter.workspace {
            Some(w) => js(w)
            None => Null
          },
        ),
        ("session", js(session)),
        ("by", starter.by.to_json()),
        (
          "chatTitle",
          match starter.chat_title {
            Some(t) => js(t)
            None => Null
          },
        ),
        ("args", rest),
      ])
      let answer = (self.host.ask)(id, request) catch {
        BusRefused(message) => {
          let low = @jscase.lower(message)
          // A station from before this has no `login.call`: told so, not as the login's own failure.
          if (low.contains("unknown") || low.contains("not found") || low.contains("no such method")) &&
            low.contains("login") {
            raise Failure(
              "\{(self.host.station_name)(id)} runs a still.fail that cannot be logged in from another station yet: update it, or log in on it from a chat of its own",
            )
          }
          raise BusRefused(message)
        }
        e => raise e
      }
      match get(Some(answer), "text") {
        Some(Str(u)) => @jsjson.raw_text(u)
        _ => raise Failure("\{(self.host.station_name)(id)} gave no answer")
      }
    }),
  }
}
