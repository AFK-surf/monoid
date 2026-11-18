// session_send (station/src/sessions/messages.ts): one session's agent writes to another's, on this station or another
// station of the workspace. The message is kept in the other chat's letters, headed with a link back to the sender's
// chat, and handed to the sessions there like any message; they answer the same way.

///|
pub let session_message_method : String = "session.message"

///|
let max_text : Int = 200000

///|
/// station/src/store/rows.ts STILLFAIL_SURFACE.
pub let stillfail_surface : String = "chat"

///|
/// args.ts `jsString`.
pub fn js_string(v : J) -> String {
  match v {
    Str(u) => @jsjson.text(u)
    Null => "null"
    other => stringify(other)
  }
}

///|
/// A chat by its title, linked when it has a link, as written on `surface`.
pub fn chat_named(surface : String, title : String, link : String?) -> String {
  match link {
    Some(l) if surface == stillfail_surface => {
      let t = replace_all(replace_all(title, "[", ""), "]", "")
      "[\{t}](\{l})"
    }
    Some(l) => {
      let t = title
        |> replace_all("&", "&amp;")
        |> replace_all("<", "&lt;")
        |> replace_all(">", "&gt;")
        |> replace_all("|", "/")
      "<\{l}|\{t}>"
    }
    None => title
  }
}

///|
/// Who a message comes from, as its header shows it.
pub fn message_header(
  words : Words,
  lang : String,
  surface : String,
  title : String,
  link : String?,
  opened : Bool,
  led : Bool?,
) -> String {
  let key = if !opened {
    "station.session.from"
  } else {
    match led {
      Some(true) => "station.session.ledBy"
      Some(false) => "station.session.openedForYou"
      None => "station.session.openedBy"
    }
  }
  words.tr(lang, key, args=[("from", chat_named(surface, title, link))])
}

///|
async fn sender_title(w : World, row : J, thread : J) -> String {
  let named = if thread is Null { None } else { str_of(Some(w.dep("given", [thread]))) }
  let own = match str_of(at(Some(row), "title")) {
    Some(t) if trim(t) != "" => Some(trim(t))
    _ => None
  }
  let first = if thread is Null ||
    named is Some(_) ||
    own is Some(_) ||
    str_of(at(Some(thread), "surface")) == Some(stillfail_surface) {
    J::Null
  } else {
    w.store("firstText", [at(Some(thread), "id").unwrap_or(Null)])
  }
  match named {
    Some(n) => n
    None =>
      match own {
        Some(o) => o
        None =>
          if thread is Null {
            str_of(at(Some(row), "key")).unwrap_or("")
          } else {
            str_of(Some(w.dep("titleOf", [thread, first, Null]))).unwrap_or("")
          }
      }
  }
}

///|
/// A sender's title when its preferred conversation is ready: Some(Null) for no session, None to prepare first.
pub async fn sender_title_if_ready(w : World, key : String) -> J? {
  let row = w.store("getSession", [js(key)])
  if row is Null {
    return Some(Null)
  }
  let mut thread = J::Null
  try {
    let home = w.store("sessionHomeThread", [js(key)])
    let selected = if nullish(Some(home)) { w.store_u("latestThreadIfReady", [js(key)]) } else { Some(home) }
    guard selected is Some(s) else { return None }
    thread = at(Some(s), "thread").unwrap_or(Null)
  } catch {
    _ => ()
  }
  Some(js(sender_title(w, row, thread)))
}

///|
/// The sender's chat as a message from it is headed: its title, and its link once the station is in a workspace.
pub async fn sender(w : World, key : String) -> (String, String?) {
  let row = w.store("getSession", [js(key)])
  if row is Null {
    raise fail_("unknown session")
  }
  let mut thread = J::Null
  try {
    thread = at(Some(w.dep("sessionThreadOf", [js(key)])), "thread").unwrap_or(Null)
  } catch {
    _ => ()
  }
  let title = sender_title(w, row, thread)
  (title, str_of(Some(w.hub("link", [js(key)]))))
}

///|
async fn chat_of(w : World, key : String, named : String) -> (String, String?) {
  sender(w, key) catch {
    _ => (named, None)
  }
}

///|
fn link_j(l : String?) -> J {
  jopt(l)
}

///|
/// session_send from session `key`: to a chat of its workspace, on this station or another of that workspace.
pub async fn session_send(w : World, key : String, args : J) -> String {
  let to = trim(match at(Some(args), "to") { None => ""; Some(v) => js_string(v) })
  let text = trim(match at(Some(args), "text") { None => ""; Some(v) => js_string(v) })
  if to == "" {
    raise fail_("to is required: the other chat's link, its session key or a thread address; chat_list lists this station's")
  }
  if text == "" {
    raise fail_("text is empty")
  }
  if char_count(text) > max_text {
    raise fail_("text is too long (at most \{max_text} characters): put the rest in a file and name its path")
  }
  let paths = match at(Some(args), "files") {
    Some(Arr(xs)) => xs.map(js_string)
    _ => []
  }
  let (title, link) = sender(w, key)
  let here = match link {
    Some(l) => str_of(Some(w.dep("linkedStation", [js(l)])))
    None => None
  }
  let linked_to = str_of(Some(w.dep("linkedStation", [js(to)])))
  let linked_session = w.dep("linkedSession", [js(to)])
  let named0 = str_of(at_i(Some(linked_session), 0)).unwrap_or(to)
  let handed = if linked_to is None || linked_to == here { w.store("handedTo", [js(named0)]) } else { J::Null }
  let there = if handed is Null { linked_to } else { str_of(at(Some(handed), "station")) }
  if there is Some(st) && there != here {
    let target = if handed is Null { str_of(at_i(Some(linked_session), 0)) } else { Some(named0) }
    guard target is Some(target) else { raise fail_("\{to} names no chat") }
    let call = w.dep("peersOf", [js(key)])
    if call is Null {
      raise fail_("other stations cannot be reached from this one yet")
    }
    let files = arr_of(Some(w.dep("sendable", [js(key), jsa(paths)]))).unwrap_or([])
    let mut request = jo([
      ("method", js(session_message_method)),
      ("session", js(key)),
      ("to", js(target)),
      ("text", js(text)),
      ("from", jo([("title", js(title)), ("link", link_j(link))])),
    ])
    let answer = try {
      if files.length() > 0 {
        request = set_field(request, "files", w.dep("sendAlong", [call, js(st), js(key), js(target), ja(files)]))
      }
      w.call_fn(call, [js(st), request])
    } catch {
      e => {
        let old = thrown_message(e)
        if thrown_kind(e) == "Refused" && w.dep("fromBefore", [js(old)]) is Bool(true) {
          raise fail_("not sent to \{to}: that station is not updated yet and takes no \{if files.length() > 0 { "files" } else { "messages" }}")
        }
        if thrown_kind(e) == "Refused" {
          raise fail_("not sent to \{to}: \{old}")
        }
        raise fail_("not sent to \{to}: \{old}. If it timed out, it may have arrived: ask before sending it again")
      }
    }
    let place = str_of(at(Some(answer), "thread")).unwrap_or("its chat")
    let named_ = match str_of(at(Some(answer), "title")) {
      Some(t) if trim(t) != "" => t
      _ => target
    }
    let their_link = match str_of(at(Some(answer), "link")) {
      Some(l) if l != "" => Some(l)
      _ => Some(to)
    }
    kept_out(w, key, named_, their_link, text)
    return "Sent to \{target} on station \{st} (\{place}). Its agent answers with session_send to your chat."
  }
  let what = w.dep("named", [js(to), w.dep("scopeOf", [js(key)]), jb(true)])
  let mut thread = J::Null
  let mut targets : Array[String] = []
  if str_of(at(Some(what), "type")) == Some("session") {
    let wkey = str_of(at(Some(what), "key")).unwrap_or("")
    if wkey == key {
      raise fail_("that is this session: use chat_post for your own conversations")
    }
    thread = w.dep("sessionThreadOf", [js(wkey)])
    let row = at(Some(thread), "thread")
    targets = arr_of(Some(w.store("threadSessions", [at(row, "id").unwrap_or(Null)])))
      .unwrap_or([])
      .map(m => str_of(at(Some(m), "session")).unwrap_or(""))
    if targets.contains(key) {
      raise fail_(
        "\{thread_address(str_of(at(row, "channel")).unwrap_or(""), str_of(at(row, "threadTs")).unwrap_or(""))} is one of your conversations: use chat_post there",
      )
    }
  } else {
    let wthread = at(Some(what), "thread").unwrap_or(Null)
    let members = arr_of(Some(w.store("threadSessions", [at(Some(wthread), "id").unwrap_or(Null)]))).unwrap_or([])
    if members.iter().any(m => str_of(at(Some(m), "session")) == Some(key)) {
      raise fail_("\{to} is one of your conversations: use chat_post there")
    }
    guard members.length() > 0 && at(Some(members[0]), "connect") is Some(connect) && !(connect is Null) else {
      raise fail_("no agent takes part in \{to}")
    }
    thread = jo([("thread", wthread), ("connect", connect)])
    targets = members.map(m => str_of(at(Some(m), "session")).unwrap_or(""))
  }
  let row = at(Some(thread), "thread")
  if w.store("manuallyArchived", [at(row, "id").unwrap_or(Null)]) is Bool(true) {
    raise fail_("not sent to \{to}: that chat was archived by hand: it takes no messages until someone restores it")
  }
  let files = if paths.length() > 0 {
    attach(w, key, paths, if targets.length() > 0 { targets[0] } else { key })
  } else {
    J::Arr([])
  }
  let place = post_from(w, thread, key, title, link, text, targets, files, false)
  let home = match str_of(at(row, "home")) {
    Some(h) => h
    None => targets[0]
  }
  let (their_title, their_link) = chat_of(w, home, to)
  kept_out(w, key, their_title, their_link, text)
  "Sent to \{place} (agents there: \{targets.join(", ")}). They answer with session_send to your chat."
}

///|
/// A message another station's session sent here, from station `peer`, in workspace `ws` (None: any).
pub async fn from_peer(w : World, peer : String, request : J, ws : String?) -> J {
  let text = match str_of(at(Some(request), "text")) {
    Some(t) => trim(t)
    None => ""
  }
  let target = str_of(at(Some(request), "to")).unwrap_or("")
  let from = str_of(at(Some(request), "session")).unwrap_or("")
  if text == "" || target == "" || from == "" || char_count(text) > max_text {
    raise fail_("a message needs to, session and text (at most \{max_text} characters)")
  }
  let handed = w.store("handedTo", [js(target)])
  if !(handed is Null) {
    let peers = w.hub("peers", [])
    if !(peers is Null) && str_of(at(Some(handed), "station")) != Some(peer) {
      let forwarded = match ws {
        Some(x) => spread(request, jo([("workspace", js(x))]))
        None => spread(request, J::Obj([]))
      }
      let peers2 = w.hub("peers", [])
      return w.call_fn(peers2, [at(Some(handed), "station").unwrap_or(Null), forwarded])
    }
  }
  if w.store("getSession", [js(target)]) is Null || !(w.dep("reachable", [js(target), jopt(ws), jb(true)]) is Bool(true)) {
    raise fail_("no session \{target} on this station (it may have been deleted)")
  }
  let thread = w.dep("sessionThreadOf", [js(target)])
  let row = at(Some(thread), "thread")
  let tid = at(row, "id").unwrap_or(Null)
  if w.store("manuallyArchived", [tid]) is Bool(true) {
    raise fail_("that chat was archived by hand: it takes no messages until someone restores it")
  }
  let targets = arr_of(Some(w.store("threadSessions", [tid]))).unwrap_or([]).map(m => str_of(at(Some(m), "session")).unwrap_or(""))
  let files = w.dep("claim", [js(peer), js(from), js(if targets.length() > 0 { targets[0] } else { target }), at(Some(request), "files").unwrap_or(Null)])
  let title = match str_of(at(at(Some(request), "from"), "title")) {
    Some(t) if trim(t) != "" => t
    _ => from
  }
  let link = match str_of(at(at(Some(request), "from"), "link")) {
    Some(l) if l != "" => Some(l)
    _ => None
  }
  let opener = w.store("openerOf", [js(target)])
  let opened = at(Some(request), "opened") is Some(Bool(true)) &&
    !(opener is Null) &&
    str_of(at(Some(opener), "parentStation")) == Some(peer) &&
    str_of(at(Some(opener), "parent")) == Some(from)
  let place = post_from(w, thread, "\{peer}/\{from}", title, link, text, targets, files, opened)
  let home = match str_of(at(row, "home")) {
    Some(h) => h
    None => target
  }
  let (here, at_) = chat_of(w, home, target)
  jo([("thread", js(place)), ("title", js(here)), ("link", link_j(at_))])
}

///|
/// Records `text` from `author` in `thread`, headed with where it comes from, with `given` files, and hands it to
/// `targets`: a letter, kept apart and posted nowhere, but for the first message of a chat an agent opened (`opened`),
/// said in it. Its address.
pub async fn post_from(
  w : World,
  thread : J,
  author : String,
  title : String,
  link : String?,
  text : String,
  targets : Array[String],
  given : J,
  opened : Bool,
) -> String {
  let identity = message_identity(w, author)
  let row = at(Some(thread), "thread")
  let led = if opened && targets.length() > 0 {
    let opener = w.store("openerOf", [js(targets[0])])
    if opener is Null {
      None
    } else {
      bool_of(at(Some(opener), "led"))
    }
  } else {
    None
  }
  let surface = str_of(at(row, "surface")).unwrap_or("")
  let mut said = "\{message_header(w.words, w.lang.val, surface, title, link, opened, led)}\n\n\{text}"
  let data_dir = str_of(at(Some(w.config()), "dataDir")).unwrap_or("")
  let files = w.dep("keep", [given, js(join_path([data_dir, "thumbs"]))])
  let here = thread_ref(row)
  let tid = at(row, "id").unwrap_or(Null)
  let connect = str_of(at(Some(thread), "connect")).unwrap_or("")
  let ts = if !opened {
    w.hub("nextTs", [])
  } else {
    try {
      w.chat(connect, "post", [here, js(said), files])
    } catch {
      e => {
        let page = if targets.length() > 0 { str_of(Some(w.hub("link", [js(targets[0])]))) } else { None }
        let none = arr_of(Some(files)).unwrap_or([]).length() == 0
        if none || page is None || !thrown_message(e).contains("missing_scope") {
          raise e
        }
        let pair = w.dep("slackWithFiles", [js(said), files, js(page.unwrap())])
        let sent = w.chat(connect, "post", [here, at_i(Some(pair), 0).unwrap_or(Null), ja([])])
        said = str_of(at_i(Some(pair), 1)).unwrap_or("")
        sent
      }
    }
  }
  let hearing = jsa(targets.filter(t => t != author))
  if opened {
    let fields = [
      ("thread", tid),
      ("ts", ts),
      ("authorKind", js("agent")),
      ("author", js(author)),
      ("text", js(said)),
      ("attachments", files),
    ]
    if identity is Some(i) {
      fields.push(("agentIdentity", i))
    }
    let n = at_i(Some(w.store("insertMessage", [jo(fields)])), 0).unwrap_or(Null)
    w.hub("deliver", [tid, n, hearing, js(said)]) |> ignore
  } else {
    let n = w.store("insertLetter", [
      jo([
        ("thread", tid),
        ("ts", ts),
        ("authorKind", js("agent")),
        ("author", js(author)),
        ("text", js(said)),
        ("attachments", files),
        ("letter", jo([("way", js("in")), ("title", js(title)), ("link", link_j(link))])),
      ]),
    ])
    w.hub("deliverLetter", [tid, n, hearing]) |> ignore
  }
  thread_address(str_of(at(row, "channel")).unwrap_or(""), str_of(at(row, "threadTs")).unwrap_or(""))
}

///|
/// What session `key` wrote another chat, kept in its own chat as a letter going out.
async fn kept_out(w : World, key : String, title : String, link : String?, text : String) -> Unit {
  let own = try {
    w.dep("sessionThreadOf", [js(key)])
  } catch {
    _ => return
  }
  let row = at(Some(own), "thread")
  let surface = str_of(at(row, "surface")).unwrap_or("")
  let said = "\{w.tr("station.session.to", args=[("to", chat_named(surface, title, link))])}\n\n\{text}"
  let ts = w.hub("nextTs", [])
  w.store("insertLetter", [
    jo([
      ("thread", at(row, "id").unwrap_or(Null)),
      ("ts", ts),
      ("authorKind", js("agent")),
      ("author", js(key)),
      ("text", js(said)),
      ("letter", jo([("way", js("out")), ("title", js(title)), ("link", link_j(link))])),
    ]),
  ])
  |> ignore
}
