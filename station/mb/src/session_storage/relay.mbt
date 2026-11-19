// A chat relayed to a channel (station/src/sessions/relay.ts): a person picks a Slack channel, a Feishu/Lark group or a
// group connect's space one of the station's connects' bots is in, and the chat's agent goes on there too. The station starts the
// conversation there itself (who relayed it, from which chat, their note), or joins a Slack thread a person gave the
// link of, makes it one of the agent's conversations, says so in the chat it came from, and tells the agent. Each
// connect's chat surface is the station's (`chat.<method>` with its connect's id; `chat.has` whether it offers one);
// the words are its (`fn.tr`, `fn.stationLang`, `fn.titleOf`).

///|
priv struct RelayVia {
  id : String
  kind : String
  bind : Json
}

///|
async fn Storage::agent_of(self : Storage, thread : Json) -> String {
  match sessions_of(self.ask("store.threadSessions", [get(thread, "id").unwrap_or(Json::null())])).get(0) {
    Some(s) => s
    None => raise failed("this chat has no agent to go on with")
  }
}

///|
async fn Storage::chat_has(self : Storage, connect : String, method : String) -> Bool {
  self.ask("chat.has", [js(connect), js(method)]) is True
}

///|
async fn Storage::chat_call(self : Storage, connect : String, method : String, args : Array[Json]) -> Json {
  self.ask("chat." + method, [js(connect), ..args])
}

///|
/// The connects of the session's workspace that are on and connected, with the surface each speaks through.
async fn Storage::connects_for(self : Storage, session : String) -> Array[RelayVia] {
  let home = items(Some(self.ask("hub.workspaces", []))).get(0).map(w => as_str(Some(w))).unwrap_or(None)
  let ws = self.ws_of(Some(session))
  let out = []
  for c in items(get(self.ask("hub.config", []), "connects")) {
    let id = str(c, "id").unwrap_or("")
    if !(get(c, "enabled") is Some(True)) {
      continue
    }
    match home {
      Some(h) => if Some(str(c, "workspace").unwrap_or(h)) != ws { continue }
      None => ()
    }
    let kind = str(c, "kind").unwrap_or("")
    if !(self.ask("hub.hasChat", [js(id)]) is True) || !self.chat_has(id, "places") || !self.chat_has(id, "begin") {
      continue
    }
    let shown = if kind == "group" {
      "group"
    } else if kind == "feishu" {
      if self.chat_has(id, "platform") && self.chat_call(id, "platform", []) == js("lark") { "lark" } else { "feishu" }
    } else {
      "slack"
    }
    out.push({ id, kind: shown, bind: get(c, "bind").unwrap_or(jo([])) })
  }
  out
}

///|
/// The bot a chat goes on through unless another is picked.
async fn Storage::preferred_of(self : Storage, session : String, connects : Array[RelayVia]) -> String? {
  guard self.session(session) is Some(row) else { return None }
  let runtime = get(row, "runtime")
  let runs = connects.filter(c => get(c.bind, "runtime") == runtime)
  let found = match connects.iter().find_first(c => Some(js(c.id)) == get(row, "connect")) {
    Some(c) => Some(c)
    None =>
      match runs.iter().find_first(c => get(c.bind, "profile") == get(row, "profile")) {
        Some(c) => Some(c)
        None => {
          let model = get(row, "model")
          match runs.iter().find_first(c => !nullish(model) && get(c.bind, "model") == model) {
            Some(c) => Some(c)
            None => runs.get(0)
          }
        }
      }
  }
  found.map(c => c.id)
}

///|
/// String.prototype.localeCompare as ICU's root order has it for what a place is named: letters by their letter
/// first, a lower one before its upper one, the rest by their code points.
fn locale_compare(a : String, b : String) -> Int {
  let c = js_compare(a.to_lower(), b.to_lower())
  if c != 0 {
    return if c < 0 { -1 } else { 1 }
  }
  // (equal but for case: the lower first)
  let d = js_compare(b, a)
  if d < 0 {
    -1
  } else if d > 0 {
    1
  } else {
    0
  }
}

///|
/// Where a chat can be relayed to: each connect's places, read now (relay.ts `relayPlaces`).
pub async fn Storage::relay_places(self : Storage, thread : Json) -> Array[Json] {
  let session = self.agent_of(thread)
  let connects = self.connects_for(session)
  let preferred = self.preferred_of(session, connects)
  let out = []
  for c in connects {
    let name = if self.chat_has(c.id, "botName") {
      match self.chat_call(c.id, "botName", []) {
        String(n) if n != "" => n
        _ => c.id
      }
    } else {
      c.id
    }
    let me = if self.chat_has(c.id, "identity") { self.chat_call(c.id, "identity", []) } else { Json::null() }
    let nonempty = (v : Json?) => match v {
      Some(String(s)) if s != "" => js(s)
      _ => Json::null()
    }
    let team_id = nonempty(Some(self.chat_call(c.id, "workspace", [])))
    let shown = [
      ("id", js(c.id)),
      ("kind", js(c.kind)),
      ("name", js(name)),
      ("team", nonempty(get(me, "team"))),
      ("botImage", nonempty(get(me, "botImage"))),
      ("teamId", team_id),
      ("preferred", jb(Some(c.id) == preferred)),
    ]
    try {
      let used : Map[String, Json] = {}
      for pair in items(Some(self.ask("store.relayedTo", [js(c.id)]))) {
        if pair is Array([String(p), at]) {
          used[p] = at
        }
      }
      let places = items(Some(self.chat_call(c.id, "places", []))).map(p => match (str(p, "id"), p) {
        (Some(id), Object(m)) if used.get(id) is Some(at) => {
          let n = m.copy()
          n["used"] = at
          Json::object(n)
        }
        _ => p
      })
      let used_of = (p : Json) => num(p, "used").unwrap_or(-1.0)
      places.sort_by((a, b) => {
        let d = used_of(b) - used_of(a)
        if d != 0.0 {
          if d < 0.0 { -1 } else { 1 }
        } else {
          locale_compare(str(a, "name").unwrap_or(""), str(b, "name").unwrap_or(""))
        }
      })
      let joins = self.chat_has(c.id, "joins") && self.chat_call(c.id, "joins", []) is True && self.chat_has(c.id, "openPlaces")
      let open = if joins {
        try Some(self.chat_call(c.id, "openPlaces", [])) catch {
          e => {
            self.log("warn", "hub", "a connect's open channels were not read", jo([("connect", js(c.id)), ("error", js(message_of(e)))]))
            None
          }
        }
      } else {
        None
      }
      let fields = [..shown, ("places", ja(places))]
      match open {
        Some(o) => {
          fields.push(("joins", jb(true)))
          fields.push(("open", o))
        }
        None => ()
      }
      out.push(jo(fields))
    } catch {
      e => {
        self.log("warn", "hub", "a connect's places were not read for relaying", jo([("connect", js(c.id)), ("error", js(message_of(e)))]))
        out.push(jo([..shown, ("places", ja([])), ("error", js(message_of(e)))]))
      }
    }
  }
  out
}

///|
fn place_name(place : Json) -> String {
  if str(place, "kind") == Some("channel") {
    "#\{str(place, "name").unwrap_or("")}"
  } else {
    str(place, "name").unwrap_or("")
  }
}

///|
priv struct Target {
  via : RelayVia
  existing : Json?
  channel : String
  place : Json
}

///|
async fn Storage::target_of(self : Storage, connects : Array[RelayVia], target : Json) -> Target {
  let mut via : RelayVia? = None
  let mut existing : Json? = None
  match str(target, "link") {
    Some(link) => {
      let wanted = str(target, "connect")
      let order = [..connects.filter(o => Some(o.id) == wanted), ..connects.filter(o => Some(o.id) != wanted)]
      for candidate in order {
        existing = if self.chat_has(candidate.id, "threadOf") { some_of(self.chat_call(candidate.id, "threadOf", [js(link)])) } else { None }
        if existing is Some(_) {
          via = Some(candidate)
          break
        }
      }
      if via is None || existing is None {
        raise failed("not a link to a message of a Slack workspace this station's connects are in")
      }
    }
    None => {
      let id = str(target, "connect").unwrap_or("")
      via = connects.iter().find_first(c => c.id == id)
      if via is None {
        raise failed("connect \{js_text(get(target, "connect"))} cannot take this chat")
      }
    }
  }
  let via = via.unwrap()
  let channel = match existing {
    Some(e) => str(e, "channel").unwrap_or("")
    None => js_text(get(target, "channel"))
  }
  let mut place = items(Some(self.chat_call(via.id, "places", []))).iter().find_first(p => str(p, "id") == Some(channel))
  let join = get(target, "channel") is Some(_) && get(target, "join") is Some(True)
  if place is None && join && self.chat_has(via.id, "join") && self.chat_has(via.id, "openPlaces") {
    match items(Some(self.chat_call(via.id, "openPlaces", []))).iter().find_first(p => str(p, "id") == Some(channel)) {
      Some(open) => {
        ignore(self.chat_call(via.id, "join", [js(channel)]))
        place = Some(open)
      }
      None => ()
    }
  }
  guard place is Some(place) else { raise failed("the bot is not in \{channel}") }
  { via, existing, channel, place }
}

///|
/// The people of the place a chat would be relayed to, to be mentioned in the note.
pub async fn Storage::relay_people(self : Storage, thread : Json, target : Json) -> Json {
  let t = self.target_of(self.connects_for(self.agent_of(thread)), target)
  if self.chat_has(t.via.id, "peopleIn") {
    match self.chat_call(t.via.id, "peopleIn", [js(t.channel)]) {
      Array(_) as a => a
      _ => ja([])
    }
  } else {
    ja([])
  }
}

///|
fn word_unit(u : Int?) -> Bool {
  match u {
    Some(c) => c == '_' || (!(c >= 0xd800 && c <= 0xdfff) && @jscase.is_word_point(c))
    None => false
  }
}

///|
/// The note as said there: each `@name` of one of `people` becomes their mention on the platform (relay.ts
/// `mentioned`).
pub fn mentioned(note : String, people : Array[Json], mention : (String) -> String) -> String {
  if !note.contains("@") || people.length() == 0 {
    return note
  }
  let names : Array[(String, String)] = []
  for p in people {
    let id = str(p, "id").unwrap_or("")
    for n in [str(p, "name").unwrap_or(""), str(p, "aka").unwrap_or("")] {
      if n != "" {
        names.push((id, n))
      }
    }
  }
  // (a stable sort, the longest first)
  let sorted = names.mapi((i, n) => (i, n))
  sorted.sort_by((a, b) => {
    let d = b.1.1.length() - a.1.1.length()
    if d != 0 { d } else { a.0 - b.0 }
  })
  let n = note.length()
  let unit = (i : Int) => if i >= 0 && i < n { Some(note.unsafe_charcode_at(i)) } else { None }
  let out = StringBuilder::new()
  let mut i = 0
  while i < n {
    let starts = note.unsafe_charcode_at(i) == '@' && !word_unit(unit(i - 1))
    let found = if starts {
      sorted.iter().find_first(x => cut(note, i + 1).has_prefix(x.1.1))
    } else {
      None
    }
    match found {
      Some((_, (id, name))) => {
        let end = i + 1 + name.length()
        let last = name.unsafe_charcode_at(name.length() - 1)
        let ascii_word = (last >= 'A' && last <= 'Z') || (last >= 'a' && last <= 'z') || (last >= '0' && last <= '9') || last == '_'
        if ascii_word && word_unit(unit(end)) {
          out.write_string(cut(note, i, end=i + 1))
          i += 1
          continue
        }
        out.write_string(mention(id))
        i = end
      }
      None => {
        out.write_string(cut(note, i, end=i + 1))
        i += 1
      }
    }
  }
  out.to_string()
}

///|
async fn Storage::mention_of(self : Storage, connect : String, id : String) -> String {
  if self.chat_has(connect, "mention") {
    as_str(Some(self.chat_call(connect, "mention", [js(id)]))).unwrap_or("<@\{id}>")
  } else {
    "<@\{id}>"
  }
}

///|
/// Relays a chat by `relayer` (`{name, email}`), with their `note` (relay.ts `relay`).
pub async fn Storage::relay(self : Storage, thread : Json, relayer : Json, target : Json, note : String) -> Json {
  let by = str(relayer, "name").unwrap_or("")
  let session = self.agent_of(thread)
  let t = self.target_of(self.connects_for(session), target)
  let c = t.via
  let surface = self.ask("hub.surface", [js(c.id)])
  match t.existing {
    Some(e) => {
      let known = self.ask("store.threadAt", [surface, get(e, "channel").unwrap_or(Json::null()), get(e, "threadTs").unwrap_or(Json::null())])
      let members = if nullish(Some(known)) {
        []
      } else {
        items(Some(self.ask("store.threadSessions", [get(known, "id").unwrap_or(Json::null())]))).filter(m => str(m, "connect") == Some(c.id))
      }
      if members.iter().any(m => str(m, "session") == Some(session)) {
        raise failed("this chat's agent is in that thread already")
      }
      if members.length() > 0 {
        raise failed("another chat's agent is in that thread: it cannot be relayed there")
      }
    }
    None => ()
  }
  let lang = self.ask("fn.stationLang", [])
  let title = as_str(Some(self.ask("fn.titleOf", [thread, Json::null(), Json::null()]))).unwrap_or("")
  let page = as_str(Some(self.ask("hub.link", [js(session)])))
  let from = match page {
    Some(p) => "[\{title.replace_all(old="[", new="").replace_all(old="]", new="")}](\{p})"
    None => title
  }
  let people = if note.contains("@") && self.chat_has(c.id, "peopleIn") {
    try items(Some(self.chat_call(c.id, "peopleIn", [js(t.channel)]))) catch { _ => [] }
  } else {
    []
  }
  let mentions : Map[String, String] = {}
  for p in people {
    match str(p, "id") {
      Some(id) => mentions[id] = self.mention_of(c.id, id)
      None => ()
    }
  }
  let said = mentioned(js_trim(note), people, id => mentions.get(id).unwrap_or("<@\{id}>"))
  let user = if self.chat_has(c.id, "userOf") {
    try as_str(Some(self.chat_call(c.id, "userOf", [js(str(relayer, "email").unwrap_or(""))]))) catch { _ => None }
  } else {
    None
  }
  let who = match user {
    Some(u) => self.mention_of(c.id, u)
    None => by
  }
  let tr = async fn(key : String, vars : Array[(String, Json)]) {
    as_str(Some(self.ask("fn.tr", [lang, js(key), jo(vars)]))).unwrap_or(key)
  }
  let opening = tr("station.relay.opening", [("who", js(who)), ("chat", js(from))]) + (if said == "" { "" } else { "\n\n\{said}" })
  let (begun_thread, begun_ts) = match t.existing {
    Some(e) => (e, self.chat_call(c.id, "post", [e, js(opening), ja([])]))
    None => {
      // (a group space's conversation is a topic of its own, called as the chat is)
      let b = self.chat_call(c.id, "begin", [js(t.channel), js(opening), js(title)])
      (get(b, "thread").unwrap_or(Json::null()), get(b, "ts").unwrap_or(Json::null()))
    }
  }
  let bchannel = str(begun_thread, "channel").unwrap_or("")
  let bts = str(begun_thread, "threadTs").unwrap_or("")
  let there = self.ask("store.openThread", [surface, js(bchannel), js(bts), Json::null(), js(by)])
  let there_id = get(there, "id").unwrap_or(Json::null())
  self.st.tell("store.noteRelayed", [js(c.id), js(t.channel)])
  self.st.tell("store.joinThread", [there_id, js(session), js(c.id)])
  self.st.tell("store.insertMessage", [jo([("thread", there_id), ("ts", begun_ts), ("authorKind", js(station_author)), ("author", js(station_author)), ("text", js(opening)), ("attachments", ja([]))])])
  let into = self.chat_has(c.id, "edit")
  if into {
    self.st.tell("hub.setOpening", [there_id, jo([("session", js(session)), ("ts", begun_ts)])])
  }
  let to = thread_address(bchannel, bts)
  let link = if self.chat_has(c.id, "permalink") { as_str(Some(self.chat_call(c.id, "permalink", [begun_thread]))) } else { None }
  let name = match t.existing {
    Some(_) => tr("station.relay.threadIn", [("place", js(place_name(t.place)))])
    None => place_name(t.place)
  }
  let named = match link {
    Some(l) => "[\{name}](\{l})"
    None => name
  }
  match items(Some(self.ask("store.threadSessions", [get(thread, "id").unwrap_or(Json::null())]))).iter().find_first(m => str(m, "session") == Some(session)) {
    Some(here) => {
      let text = "↗ " + tr("station.relay.relayed", [("who", js(by)), ("place", js(named))])
      let connect = str(here, "connect").unwrap_or("")
      try {
        let ts = self.ask("hub.chatPost", [js(connect), jo([("channel", get(thread, "channel").unwrap_or(Json::null())), ("threadTs", get(thread, "threadTs").unwrap_or(Json::null()))]), js(mark_notice(text)), ja([])])
        self.st.tell("store.insertMessage", [jo([("thread", get(thread, "id").unwrap_or(Json::null())), ("ts", ts), ("authorKind", js(station_author)), ("author", js(station_author)), ("text", js(text)), ("attachments", ja([]))])])
      } catch {
        e => self.log("warn", "hub", "a relay was not said in the chat it came from", jo([("thread", get(thread, "id").unwrap_or(Json::null())), ("error", js(message_of(e)))]))
      }
    }
    None => ()
  }
  let pname = str(t.place, "name").unwrap_or("")
  let where_ = match t.existing {
    Some(_) => "a Slack thread people were already talking in, in #\{pname}"
    None =>
      match str(t.place, "kind") {
        Some("channel") => "a new thread in Slack channel #\{pname}"
        Some("topics") => "a new topic in Feishu topic group \{pname}"
        Some("space") => "a new topic in the group space \{pname}"
        _ => "Feishu group \{pname}, whose conversation is now yours"
      }
  }
  let address = thread_address(str(thread, "channel").unwrap_or(""), str(thread, "threadTs").unwrap_or(""))
  let notice = "\{by} relayed the chat \{address} to \{where_}: \{to} is now one of your conversations, and replies there come to you. " +
    "The station posted its first message (who relayed it, a link to this chat\{if said == "" { "" } else { ", and their note" }}). " +
    (if t.existing is Some(_) { "Read what was said there before first (slack_api conversations.replies with channel \{bchannel} and ts \{bts}). " } else { "" }) +
    "Post there now with chat_post to=\{to}: what this conversation is about, what is decided and what is open, so the people there can take part without reading it" +
    (if into { " (without files or a card, it is added to the station's first message there, which is what people see without opening the thread: write it to read on from it). " } else { ". " }) +
    "\{if said == "" { "" } else { "Their note: \{quoted(said)}. " }}Keep answering the chat it came from too."
  self.st.tell("hub.notify", [js(session), js(notice)])
  self.log("info", "hub", "chat relayed", jo([("thread", get(thread, "id").unwrap_or(Json::null())), ("session", js(session)), ("connect", js(c.id)), ("to", js(to))]))
  jo([("thread", there_id), ("to", js(to)), ("place", js(name)), ("link", jopt(link))])
}
