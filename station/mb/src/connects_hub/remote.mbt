// A connect is its workspace's (connects/remote.ts): a chat of it may run on any station of the workspace. The connect
// itself (its link to its platform, its config.json entry and tokens) runs on one station, the one it was added on or
// moved to by hand (`connect.take`), and nowhere else: while that station is off, so is the connect. That station
// - takes every event of its platform, and hands one to the station a chat of its thread runs on (`connect.event`): a
//   thread it handed on before (the threads table, `connect_threads`), or a new conversation, which starts on the
//   station the connect's `station` names (absent: this one);
// - does for the chats of other stations what their surface asks (`connect.call`): posts and cards, the status lines,
//   files both ways, names, the platform's API.
// A connect is known across the workspace by its id on the station it was added on (its origin) and that station:
// there as its id, on every other station as `<id>@<origin>` (`local_of`), wherever it runs since. A station a chat of
// it runs on and that does not run it has it as a connect of its hub's whose surface is a remote one asking the station
// it runs on, and whose people and channels go into its own names books; one it was moved to has it in config.json
// under that same id. So a chat's session, and the thread it is in, keep the connect's id as the connect moves.

///|
/// What a station asks of the station a connect runs on: an event of its platform for a chat here; a call of a chat's
/// surface there; a connect moved here.
pub let event_method : String = "connect.event"

///|
pub let call_method : String = "connect.call"

///|
pub let take_method : String = "connect.take"

///|
/// A connect moved: the station it runs on now, told to the workspace's others.
pub let moved_method : String = "connect.moved"

///|
/// Whether the station asked holds a connect (its entry in its config.json): asked by one that moved it there and did
/// not hear it was taken (workspace.mbt `settle_moving`).
pub let holds_method : String = "connect.holds"

///|
/// One thread of a connect's: its chat runs on another station from now on, or on the connect's own again.
pub let route_method : String = "connect.route"

///|
/// The bots of the connects a station runs, told to the workspace's other stations as they change.
pub let bots_method : String = "connect.bots"

///|
/// The connects a station runs, as another of the workspace asks before one is added (one connect, one station).
pub let list_method : String = "connect.list"

///|
/// The kinds whose chats run on other stations: Slack's and Feishu's. A Comma connect's Tasks stay where it is.
pub let routed : Array[String] = ["slack", "feishu"]

///|
/// A connect as the workspace knows it: its id where it was added, and that station.
pub(all) struct Known {
  id : String
  origin : String
} derive(Eq, Show)

///|
pub fn Known::to_j(self : Known) -> J {
  jo([("id", js(self.id)), ("origin", js(self.origin))])
}

///|
/// The connect's id on station `here`.
pub fn local_of(c : Known, here : String) -> String {
  if c.origin == here {
    c.id
  } else {
    "\{c.id}@\{c.origin}"
  }
}

///|
/// The connect an id of station `here` names (one of its own adding has no `@`: connect ids are slugs).
pub fn known_of(id : String, here : String) -> Known {
  let at_ = @session_chats.last_index_of(id, "@")
  let n = id.length()
  if at_ > 0 && at_ < n - 1 {
    { id: @session_chats.slice(id, 0, b=at_), origin: @session_chats.slice(id, at_ + 1) }
  } else {
    { id, origin: here }
  }
}

///|
/// The connect a request names.
pub fn known_in(v : J?) -> Known? {
  match (nonempty_str(at(v, "id")), nonempty_str(at(v, "origin"))) {
    (Some(id), Some(origin)) => Some({ id, origin })
    _ => None
  }
}

///|
/// The optional calls of a surface a remote one has only where the connect's has them (the hub tells by their
/// absence).
pub let optional_calls : Array[String] = [
  "cardEnded", "download", "userName", "working", "standsAt", "api", "userEmail", "userOf", "channelName", "places", "peopleIn",
  "begin", "edit", "history",
]

///|
/// What a station a chat runs on may call of a connect's surface here: those, and the names of people and channels.
let calls : Array[String] = ["post", "person", "channel", ..optional_calls]

///|
fn truthy(v : J?) -> Bool {
  @session_chats.truthy(v)
}

///|
/// `surface` of `connect` (config.json's entry, as the hub reads it: sessions/config.ts `Connect`), as it is
/// described to another station (`Described`).
pub fn describe(connect : J, workspace : String, surface : Surface) -> J {
  let mention = match surface.get_opt("mention", [js("\u{1}")]) {
    Some(Str(u)) => @jsjson.sanitize_str(u)
    Some(other) => js_text(Some(other))
    None => "<@\u{1}>"
  }
  let at_ = @session_chats.index_of(mention, "\u{1}")
  let c = Some(connect)
  let bind = at(c, "bind")
  let bind_j = jo(
    [("runtime", at(bind, "runtime").unwrap_or(undefined()))] +
    (if truthy(at(bind, "model")) { [("model", at(bind, "model").unwrap())] } else { [] }) +
    (if truthy(at(bind, "effort")) { [("effort", at(bind, "effort").unwrap())] } else { [] }),
  )
  let said = at(at(c, "slack"), "botName")
  let link = if (surface.has)("sessionLink") {
    (surface.get)("sessionLink", [js("\u{1}"), js("\u{2}")])
  } else {
    js("<\u{1}|\u{2}>")
  }
  let fields : Array[(String, J)] = [
    ("kind", at(c, "kind").unwrap_or(undefined())),
    ("workspace", js(workspace)),
    ("mode", at(c, "mode").unwrap_or(undefined())),
    ("requireMention", at(c, "requireMention").unwrap_or(undefined())),
  ]
  if truthy(said) {
    fields.push(("botNameSaid", said.unwrap()))
  }
  fields.push(("bind", bind_j))
  fields.push(("botUserId", js(surface.bot_user_id())))
  fields.push(("botName", surface.get_opt("botName", []).unwrap_or(js(""))))
  fields.push(("identity", nullish_or_null(surface.get_opt("identity", []))))
  fields.push(("platform", nullish_or_null(surface.get_opt("platform", []))))
  fields.push(("team", (surface.get)("workspace", [])))
  fields.push(("cards", jb((surface.has)("cards"))))
  fields.push(("loginCards", jb((surface.has)("loginCards"))))
  fields.push(
    (
      "mention",
      if at_ < 0 {
        jsa(["<@", ">"])
      } else {
        jsa([@session_chats.slice(mention, 0, b=at_), @session_chats.slice(mention, at_ + 1)])
      },
    ),
  )
  fields.push(("link", link))
  fields.push(("has", jsa(optional_calls.filter(name => (surface.has)(name)))))
  // (its `begin` takes a first message's files and card, the thread it begins routed to the asking station)
  if (surface.has)("begin") {
    fields.push(("beginPost", jb(true)))
  }
  drop_undefined(jo(fields))
}

///|
/// `v ?? null`.
fn nullish_or_null(v : J?) -> J {
  match v {
    None => Null
    Some(x) => if is_undefined(x) { Null } else { x }
  }
}

///|
/// A described connect as the hub of a station its chats run on reads it (sessions/config.ts `Connect`): no profile
/// of its own (its station's are not this one's), its runtime and model as there.
pub fn connect_of(id : String, d : J) -> J {
  let bind = at(Some(d), "bind")
  jo([
    ("id", js(id)),
    ("kind", at(Some(d), "kind").unwrap_or(undefined())),
    ("enabled", jb(true)),
    ("mode", at(Some(d), "mode").unwrap_or(undefined())),
    ("requireMention", at(Some(d), "requireMention").unwrap_or(undefined())),
    ("slack", jo([("botName", at(Some(d), "botNameSaid").unwrap_or(undefined()))])),
    (
      "bind",
      jo([
        ("runtime", at(bind, "runtime").unwrap_or(undefined())),
        ("model", at(bind, "model").unwrap_or(undefined())),
        ("effort", at(bind, "effort").unwrap_or(undefined())),
      ]),
    ),
    ("workspace", at(Some(d), "workspace").unwrap_or(undefined())),
    ("remote", jb(true)),
  ])
  |> drop_undefined
}

///|
/// The bytes after a request or an answer on the mesh (mesh/bus.ts `withBytes`).
pub(all) enum Body {
  NoBody
  /// A file's, read as it is sent (mesh/files.ts `fileBytes`).
  FileBody(String, Double, Double)
  DataBody(Bytes)
}

///|
/// What another station answered: its JSON, and the bytes after it (`bytesOf`).
pub(all) struct Answer {
  json : J
  bytes : Bytes?
}

///|
/// A file a chat posts or fetches through another station: at most this.
let file_max : Double = 1073741824.0

///|
/// Asks the station a connect runs on: a call of its surface and its arguments, with bytes after it (a file it is to
/// post), answered with what the call gave (and bytes: a file it fetched).
pub struct Asker {
  ask : async (String, J, Body) -> Answer
}

///|
/// A connect of another station as the hub here uses it (`RemoteSurface`): each call asks that station
/// (`connect.call`), what it said of the connect answers the rest. Its names go into this station's names book of its
/// kind.
pub struct RemoteSurface {
  /// Its id here, the connect it is, and the station it runs on.
  id : String
  known : Known
  station : String
  described : J
  priv asker : Asker
  priv names : NameBook?
  priv fs : Fs
  priv log : Log
  /// The files of the answers `api` gave, as that station read them (the newest few, by the answer itself).
  priv files : Array[(J, Array[J])]
  /// This station's id: where a thread `begin` started is routed to on a station from before.
  priv here : () -> String
}

///|
pub fn RemoteSurface::new(
  id : String,
  known : Known,
  station : String,
  described : J,
  asker : Asker,
  names : NameBook?,
  fs : Fs,
  log : Log,
  here? : () -> String = () => "",
) -> RemoteSurface {
  { id, known, station, described, asker, names, fs, log, files: [], here }
}

///|
async fn RemoteSurface::ask_call(self : RemoteSurface, op : String, args : Array[J], body? : Body = NoBody) -> J {
  let request = jo([
    ("method", js(call_method)),
    ("workspace", at(Some(self.described), "workspace").unwrap_or(undefined())),
    ("connect", self.known.to_j()),
    ("op", js(op)),
    ("args", ja(args)),
  ])
  |> drop_undefined
  let got = (self.asker.ask)(self.station, request, body)
  nullish_or_null(at(Some(got.json), "result"))
}

///|
/// A call no one waits on: said in the log when it did not go.
fn RemoteSurface::told(self : RemoteSurface, op : String, args : Array[J]) -> Unit {
  spawn(async fn() {
    ignore(self.ask_call(op, args)) catch {
      e => self.log.warn("connects", "a call to the connect's station did not go", jo([("connect", js(self.id)), ("op", js(op)), ("error", js(thrown_message(e)))]))
    }
  })
}

///|
fn RemoteSurface::d(self : RemoteSurface, name : String) -> J? {
  at(Some(self.described), name)
}

///|
/// Where its names are kept: a Slack workspace's team (two connects of one share them), else the connect itself.
fn RemoteSurface::place(self : RemoteSurface) -> String {
  match (str_of(self.d("kind")), self.d("team")) {
    (Some("slack"), Some(t)) if truthy(Some(t)) => js_text(Some(t))
    _ => self.id
  }
}

///|
fn RemoteSurface::has(self : RemoteSurface, name : String) -> Bool {
  if optional_calls.contains(name) {
    return arr_of(self.d("has")).unwrap_or([]).iter().any(h => str_of(Some(h)) == Some(name))
  }
  match name {
    "cards" => self.d("cards") is Some(Bool(true))
    "loginCards" => self.d("loginCards") is Some(Bool(true))
    "post" | "botUserId" | "botName" | "identity" | "platform" | "mention" | "workspace" | "sessionLink" | "answerFiles"
    | "knownPerson" | "knownChannel" => true
    _ => false
  }
}

///|
fn RemoteSurface::get(self : RemoteSurface, name : String, args : Array[J]) -> J {
  if !self.has(name) && name != "cards" && name != "loginCards" {
    return undefined()
  }
  let s = (i : Int) => js_text(args.get(i))
  match name {
    "botUserId" => self.d("botUserId").unwrap_or(undefined())
    "botName" => self.d("botName").unwrap_or(undefined())
    "identity" => self.d("identity").unwrap_or(undefined())
    "platform" =>
      match self.d("platform") {
        Some(Null) | None => self.d("kind").unwrap_or(undefined())
        Some(p) => p
      }
    "mention" => {
      let m = arr_of(self.d("mention")).unwrap_or([])
      js("\{js_text(m.get(0))}\{s(0)}\{js_text(m.get(1))}")
    }
    "workspace" => self.d("team").unwrap_or(undefined())
    "cards" => jb(self.d("cards") is Some(Bool(true)))
    "loginCards" => jb(self.d("loginCards") is Some(Bool(true)))
    "sessionLink" =>
      match self.d("link") {
        Some(Null) => Null
        Some(Str(u)) =>
          js(replace_first(replace_first(@jsjson.sanitize_str(u), "\u{1}", s(0)), "\u{2}", s(1)))
        _ => undefined()
      }
    "answerFiles" =>
      match args.get(0) {
        Some(Obj(_) as a) | Some(Arr(_) as a) =>
          match self.files.iter().find_first(f => physical_equal(f.0, a)) {
            Some(f) => ja(f.1)
            None => ja([])
          }
        _ => ja([])
      }
    "knownPerson" =>
      match self.names {
        None => Null
        Some(book) => {
          let user = s(0)
          book.person(person_key(self.place(), user), async fn() { match self.ask_call("person", [js(user)]) { Null => None; p => Some(p) } }, stale=(known, _) => at(Some(known), "picture") is None).unwrap_or(Null)
        }
      }
    "knownChannel" =>
      match self.names {
        None => Null
        Some(book) => {
          let channel = s(0)
          book.channel(channel_key(self.place(), channel), async fn() { self.ask_call("channel", [js(channel)]) })
        }
      }
    "working" => {
      self.told("working", [args.get(0).unwrap_or(Null), args.get(1).unwrap_or(Null), args.get(2).unwrap_or(Null), nullish_or_null(args.get(3))])
      undefined()
    }
    "standsAt" => {
      self.told("standsAt", [args.get(0).unwrap_or(Null), args.get(1).unwrap_or(Null)])
      undefined()
    }
    _ => undefined()
  }
}

///|
/// Each file sent to the connect's station as the bytes after a call of its own: the files as that station keeps them.
async fn RemoteSurface::upload_files(self : RemoteSurface, files : Array[J]) -> Array[J] {
  let there : Array[J] = []
  for file in files {
    let path = js_text(at(Some(file), "path"))
    let size = (self.fs.size)(path)
    let kept = self.ask_call("upload", [jo([("name", at(Some(file), "name").unwrap_or(undefined())), ("size", jn(size))]) |> drop_undefined], body=FileBody(path, 0.0, size))
    guard str_of(at(Some(kept), "path")) is Some(p) else { raise fail_("the connect's station did not keep the file") }
    there.push(set_field(file, "path", js(p)))
  }
  there
}

///|
/// Its files go first, and the post names them as that station keeps them.
async fn RemoteSurface::post(self : RemoteSurface, thread : J, message : String, files : Array[J], card : J) -> String {
  let there = self.upload_files(files)
  js_text(Some(self.ask_call("post", [thread, js(message), ja(there), card])))
}

///|
/// As a post's, its files go first. A station from before takes neither files nor a card here (it would drop them)
/// and does not route the thread begun: words alone go, and the thread is routed here by `connect.route`.
async fn RemoteSurface::begin(self : RemoteSurface, channel : String, message : String, title : String, files : Array[J], card : J) -> J {
  let before = !(self.d("beginPost") is Some(Bool(true)))
  if before && (files.length() > 0 || !(card is Null)) {
    raise fail_(
      "the station that runs this connect needs an update before chat_post can attach files or a card to a new conversation's first message",
    )
  }
  let there = self.upload_files(files)
  let begun = self.ask_call("begin", [js(channel), js(message), js(title), ja(there), card])
  let thread = at(Some(begun), "thread")
  let here = (self.here)()
  match (str_of(at(thread, "channel")), str_of(at(thread, "threadTs"))) {
    (Some(ch), Some(ts)) if before &&
      here != "" &&
      routed.contains(str_of(self.d("kind")).unwrap_or("")) &&
      str_of(self.d("mode")) != Some("single-session") => {
      let request = jo([
        ("method", js(route_method)),
        ("workspace", self.d("workspace").unwrap_or(undefined())),
        ("connect", self.known.to_j()),
        ("channel", js(ch)),
        ("threadTs", js(ts)),
        ("station", js(here)),
      ])
      |> drop_undefined
      ignore((self.asker.ask)(self.station, request, NoBody))
    }
    _ => ()
  }
  begun
}

///|
async fn RemoteSurface::call(self : RemoteSurface, name : String, args : Array[J]) -> J {
  let s = (i : Int) => js_text(args.get(i))
  match name {
    "post" => js(self.post(args.get(0).unwrap_or(Null), s(1), arr_of(args.get(2)).unwrap_or([]), nullish_or_null(args.get(3))))
    "cardEnded" if self.has(name) => {
      ignore(self.ask_call("cardEnded", [args.get(0).unwrap_or(Null), args.get(1).unwrap_or(Null), args.get(2).unwrap_or(Null), args.get(3).unwrap_or(Null), args.get(4).unwrap_or(Null)]))
      undefined()
    }
    "download" if self.has(name) => {
      let request = jo([
        ("method", js(call_method)),
        ("workspace", at(Some(self.described), "workspace").unwrap_or(undefined())),
        ("connect", self.known.to_j()),
        ("op", js("download")),
        ("args", ja([args.get(0).unwrap_or(Null)])),
        ("whole", jb(true)),
      ])
      |> drop_undefined
      let got = (self.asker.ask)(self.station, request, NoBody)
      guard got.bytes is Some(bytes) else { raise fail_("the connect's station answered without the file") }
      if bytes.length().to_double() > file_max {
        raise fail_("that station's answer is too long")
      }
      js(hex(bytes))
    }
    "api" if self.has(name) => {
      // A non-JSON answer (a Feishu message's image or file) comes as bytes beside its content type and disposition,
      // given on as the Feishu connection gives it (`$feishuFile`).
      let request = jo([
        ("method", js(call_method)),
        ("workspace", at(Some(self.described), "workspace").unwrap_or(undefined())),
        ("connect", self.known.to_j()),
        ("op", js("api")),
        ("args", ja([js(s(0)), args.get(1).unwrap_or(Null)])),
        ("whole", jb(true)),
      ])
      |> drop_undefined
      let raw = (self.asker.ask)(self.station, request, NoBody)
      let got = nullish_or_null(at(Some(raw.json), "result"))
      match (raw.bytes, at(Some(got), "feishuFile")) {
        (Some(bytes), Some(Obj(_) as ff)) => {
          if bytes.length().to_double() > file_max {
            raise fail_("that station's answer is too long")
          }
          return jo([
            ("$feishuFile", js(hex(bytes))),
            ("contentType", js(js_text(at(Some(ff), "contentType")))),
            ("disposition", js(js_text(at(Some(ff), "disposition")))),
          ])
        }
        _ => ()
      }
      let answer = nullish_or_null(at(Some(got), "answer"))
      match (answer, at(Some(got), "files")) {
        (Obj(_) | Arr(_), Some(Arr(fs))) => {
          self.files.push((answer, fs))
          if self.files.length() > 64 {
            ignore(self.files.remove(0))
          }
        }
        _ => ()
      }
      answer
    }
    "userName" | "userEmail" | "userOf" | "channelName" | "peopleIn" if self.has(name) => self.ask_call(name, [js(s(0))])
    "places" if self.has(name) => self.ask_call("places", [])
    "begin" if self.has(name) => self.begin(s(0), s(1), str_of(args.get(2)).unwrap_or(""), arr_of(args.get(3)).unwrap_or([]), nullish_or_null(args.get(4)))
    "edit" if self.has(name) => self.ask_call("edit", [args.get(0).unwrap_or(Null), js(s(1)), js(s(2))])
    "history" if self.has(name) => self.ask_call("history", [args.get(0).unwrap_or(Null), js(s(1)), args.get(2).unwrap_or(Null)])
    _ => self.get(name, args)
  }
}

///|
/// The surface the hub uses.
pub fn RemoteSurface::surface(self : RemoteSurface) -> Surface {
  { has: name => self.has(name), get: (name, args) => self.get(name, args), call: async fn(name, args) { self.call(name, args) }, remote: true }
}

///|
/// What answering a call needs (`answerCall`'s arguments): the connect's surface (None where it does not run here),
/// where the files a remote chat posts are kept until they are posted, and once what a process before left there is
/// taken away.
pub struct CallAnswerer {
  surface : async (Known, String?) -> Surface?
  uploads : String
  cleared : async () -> Unit
  fs : Fs
  uuid : () -> String
}

///|
/// How a station answers another's call of one of its connects' surfaces (`answerCall`).
pub async fn CallAnswerer::answer(self : CallAnswerer, request : J, body : Bytes?, workspace : String?) -> Answer {
  let fs = self.fs
  let r = Some(request)
  let op = str_of(at(r, "op")).unwrap_or("")
  let chat = match known_in(at(r, "connect")) {
    Some(known) => (self.surface)(known, workspace)
    None => None
  }
  guard chat is Some(chat) else { raise fail_("that connect does not run on this station") }
  let args = arr_of(at(r, "args")).unwrap_or([])
  let result = (v : J) => { json: jo([("result", v)]), bytes: None }
  if op == "upload" {
    let named = match at(args.get(0), "name") {
      Some(Null) | None => "file"
      Some(n) => js_text(Some(n))
    }
    let name = match basename(named, fs.sep) {
      "" => "file"
      n => n
    }
    guard body is Some(bytes) else { raise fail_("no file came") }
    let dir = fs.join([self.uploads, (self.uuid)()])
    (self.cleared)()
    (fs.mkdir)(dir)
    let path = fs.join([dir, name])
    if bytes.length().to_double() > file_max {
      (fs.write_bytes)(path, b"")
      raise fail_("more came than the file can be")
    }
    (fs.write_bytes)(path, bytes)
    return result(jo([("path", js(path))]))
  }
  if !calls.contains(op) {
    raise fail_("no such call")
  }
  let s = (i : Int) => js_text(args.get(i))
  match op {
    "post" | "begin" => {
      let kept = arr_of(args.get(if op == "post" { 2 } else { 3 })).unwrap_or([])
      // Only what came for it, from where uploads keeps it.
      for f in kept {
        let p = js_text(at(Some(f), "path"))
        if !p.has_prefix(self.uploads + "/") && !p.has_prefix(self.uploads + "\\") {
          raise fail_("that file did not come here")
        }
      }
      defer {
        for f in kept {
          let dir = fs.dirname(js_text(at(Some(f), "path")))
          spawn(async fn() { (fs.rm)(dir) })
        }
      }
      if op == "post" {
        let posted = (chat.call)("post", [args.get(0).unwrap_or(undefined()), js(s(1)), ja(kept), args.get(3).unwrap_or(undefined())])
        result(posted)
      } else {
        if !(chat.has)("begin") {
          raise fail_("that connect has no such call")
        }
        let title = match args.get(2) {
          Some(Str(_) as t) => t
          _ => js("")
        }
        let begun = (chat.call)("begin", [js(s(0)), js(s(1)), title, ja(kept), nullish_or_null(args.get(4))])
        result(nullish_or_null(Some(begun)))
      }
    }
    "download" => {
      let got = (chat.call)("download", [args.get(0).unwrap_or(undefined())])
      let bytes = unhex(js_text(Some(got)))
      { json: jo([("size", ji(bytes.length()))]), bytes: Some(bytes) }
    }
    "api" => {
      let answer = (chat.call)("api", [js(s(0)), match args.get(1) { Some(Null) | None => jo([]); Some(p) => p }])
      // (a file as the Feishu connection gives it: its bytes go as the answer's, as remote.ts `answerCall` sends them)
      if str_of(at(Some(answer), "$feishuFile")) is Some(h) {
        let bytes = unhex(h)
        let file = jo([("contentType", js(js_text(at(Some(answer), "contentType")))), ("disposition", js(js_text(at(Some(answer), "disposition"))))])
        return { json: jo([("result", jo([("feishuFile", file)]))]), bytes: Some(bytes) }
      }
      let files = match chat.get_opt("answerFiles", [answer]) {
        Some(f) => f
        None => ja([])
      }
      result(jo([("answer", nullish_or_null(Some(answer))), ("files", files)]))
    }
    "person" => {
      let user = s(0)
      match chat.get_opt("knownPerson", [js(user)]) {
        Some(Null) | None => ()
        Some(known) => return result(known)
      }
      let name = if (chat.has)("userName") { nullish_or_null(Some((chat.call)("userName", [js(user)]))) } else { Null }
      if name is Null {
        return result(Null)
      }
      let email = if (chat.has)("userEmail") {
        nullish_or_null(Some((chat.call)("userEmail", [js(user)]) catch { _ => Null }))
      } else {
        Null
      }
      result(jo([("name", name), ("email", if email is Null { js("") } else { email })]))
    }
    "channel" => result(if (chat.has)("channelName") { nullish_or_null(Some((chat.call)("channelName", [js(s(0))]))) } else { Null })
    _ => {
      if !(chat.has)(op) {
        raise fail_("that connect has no such call")
      }
      result(nullish_or_null(Some((chat.call)(op, args))))
    }
  }
}

///|
/// The connects of other stations a chat here runs on, as the station each runs on described it last, and which
/// station that is (<data>/remote-connects.json, kept so that a chat of one has its surface as the station starts,
/// before the next event comes): by their ids here.
pub struct RemoteConnects {
  priv file : PrivateFile
  priv known : Map[String, J]
  priv surfaces : Map[String, RemoteSurface]
  priv asker : Asker
  priv names : (String) -> NameBook?
  priv here : () -> String
  /// What was learned before the file was read: not taken from it.
  priv told : Set[String]
  priv mut loaded : Bool
  priv loading : @effect.Deferred[Unit]
  priv fs : Fs
  priv log : Log
}

///|
pub fn RemoteConnects::new(data : String, here : () -> String, asker : Asker, names : (String) -> NameBook?, fs : Fs, log : Log) -> RemoteConnects {
  let r : RemoteConnects = {
    file: PrivateFile::new(fs.join([data, remote_file]), fs.write_private),
    known: {},
    surfaces: {},
    asker,
    names,
    here,
    told: Set([]),
    loaded: false,
    loading: @effect.Deferred::new(),
    fs,
    log,
  }
  spawn(async fn() {
    let kept = read_remote(fs, data)
    for e in kept {
      if !r.told.contains(e.0) {
        r.known[e.0] = e.1
      }
    }
    r.loaded = true
    // (what changed meanwhile, written now with what was kept)
    if r.told.length() > 0 {
      r.save(None)
    }
    r.told.clear()
    ignore(r.loading.succeed(()))
  })
  r
}

///|
/// Once what the file kept is known (the station waits for it before it serves).
pub async fn RemoteConnects::ready(self : RemoteConnects) -> Unit {
  self.loading.wait()
}

///|
/// Once what was changed is written down (or failed).
pub async fn RemoteConnects::written(self : RemoteConnects) -> Unit {
  self.loading.wait()
  self.file.written()
}

///|
/// What the connect's station (`station`) said of it now: kept, and its surface made again when that changed.
pub fn RemoteConnects::learn(self : RemoteConnects, id : String, station : String, described : J) -> Unit {
  let next = jo([("station", js(station)), ("described", described)])
  match self.known.get(id) {
    Some(had) if js_stringify(had) == js_stringify(next) => return
    _ => ()
  }
  self.known[id] = next
  self.surfaces.remove(id)
  self.save(Some(id))
}

///|
/// The connect runs on `station` now (moved there); none of this station's any more when that is this one.
pub fn RemoteConnects::moved(self : RemoteConnects, id : String, station : String) -> Unit {
  // (one the file may keep: once it is read)
  if !self.loaded {
    spawn(async fn() {
      self.loading.wait()
      self.moved(id, station)
    })
    return
  }
  guard self.known.get(id) is Some(had) else { return }
  if station == (self.here)() {
    self.known.remove(id)
  } else {
    self.known[id] = set_field(had, "station", js(station))
  }
  self.surfaces.remove(id)
  self.save(None)
}

///|
/// Its surface: a connect of another station a chat here ran on (none for any other id).
pub fn RemoteConnects::surface(self : RemoteConnects, id : String) -> RemoteSurface? {
  match self.surfaces.get(id) {
    Some(s) => return Some(s)
    None => ()
  }
  guard self.known.get(id) is Some(r) else { return None }
  let described = at(Some(r), "described").unwrap_or(Null)
  let made = RemoteSurface::new(
    id,
    known_of(id, (self.here)()),
    js_text(at(Some(r), "station")),
    described,
    self.asker,
    (self.names)(js_text(at(Some(described), "kind"))),
    self.fs,
    self.log,
    here=self.here,
  )
  self.surfaces[id] = made
  Some(made)
}

///|
/// As the hub reads them, with config.json's.
pub fn RemoteConnects::connects(self : RemoteConnects) -> Array[J] {
  self.known.to_array().map(e => connect_of(e.0, at(Some(e.1), "described").unwrap_or(Null)))
}

///|
/// Written off the station's thread; before the file was read, once it is (what it kept not lost).
fn RemoteConnects::save(self : RemoteConnects, id : String?) -> Unit {
  if !self.loaded {
    match id {
      Some(i) => self.told.add(i)
      None => ()
    }
    return
  }
  let text = js_stringify(from_entries(self.known.to_array())) + "\n"
  self.file.write_soon(text, e => self.log.warn("connects", "the connects of other stations were not written", jo([("error", js(thrown_message(e)))])))
}

///|
/// The connects of other stations kept in `data`, by remote id; none when the file is not there or does not read.
pub async fn read_remote(fs : Fs, data : String) -> Array[(String, J)] {
  let text = (fs.read_text)(fs.join([data, remote_file])) catch { _ => return [] }
  let raw = try parse_js(text) catch { _ => return [] }
  guard raw is Obj(_) else { return [] }
  entries_of(Some(raw)).filter(e => str_of(at(Some(e.1), "station")) is Some(_) && str_of(at(at(Some(e.1), "described"), "kind")) is Some(_))
}

///|
/// The thread an event is of: `{channel, threadTs}`.
pub fn thread_of_event(event : J) -> J {
  let e = Some(event)
  if str_of(at(e, "type")) == Some("message") {
    jo([("channel", at(at(e, "message"), "channel").unwrap_or(undefined())), ("threadTs", at(at(e, "message"), "threadTs").unwrap_or(undefined()))])
    |> drop_undefined
  } else {
    jo([("channel", at(e, "channel").unwrap_or(undefined())), ("threadTs", at(e, "threadTs").unwrap_or(undefined()))]) |> drop_undefined
  }
}
