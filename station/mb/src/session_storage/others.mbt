// Other conversations and sessions of the station, for an agent to read (station/src/sessions/others.ts, the Rust
// station's hub/others.rs: chat_list, chat_read, session_history), here and on another station of the workspace: people
// refer to another chat by its link, and the agent reads what was said there and what its agents did.

///|
pub let read_method = "session.read"

///|
pub let list_method = "session.list"

///|
/// What an agent named: a conversation, or a session (maybe one entry of its execution history).
pub enum Named {
  Thread(Json)
  Session(String, Int?)
}

///|
/// The index of the first character at or after `from` that `stop` says ends what is read; the length where none.
fn stop_at(s : String, stop : (Char) -> Bool) -> Int {
  let mut i = 0
  for c in s {
    if stop(c) {
      return i
    }
    i += if c.to_int() > 0xffff { 2 } else { 1 }
  }
  s.length()
}

///|
/// A session key a reference holds: a chat's page (…/chats/<key>), a still.fail link (…/o/<workspace>/<station>/<key>),
/// a link to execution history (?history=<key>&entry=<n>).
pub fn linked_session(reference : String) -> (String, Int?)? {
  let end = (s : String) => stop_at(s, c => "/?#)>|\"'".contains_char(c) || js_space(c))
  match reference.find("history=") {
    Some(history) => {
      let rest = cut(reference, history + 8)
      let stop = stop_at(rest, c => "&#)>|".contains_char(c) || js_space(c))
      let key = percent_decode(cut(rest, 0, end=stop))
      let digits = match reference.find("entry=") {
        Some(at) => {
          let after = cut(reference, at + 6)
          cut(after, 0, end=stop_at(after, c => !digit(c)))
        }
        None => ""
      }
      let entry = if digits != "" && digits.length() <= 15 { Some(digits_of(digits)) } else { None }
      return if key != "" { Some((key, entry)) } else { None }
    }
    None => ()
  }
  let segment = (rest : String) => percent_decode(cut(rest, 0, end=end(rest)).replace_all(old="+", new="%2B"))
  match reference.find("/chats/") {
    Some(chats) => {
      let key = segment(cut(reference, chats + 7))
      return if key != "" { Some((key, None)) } else { None }
    }
    None => ()
  }
  match reference.find("/o/") {
    Some(o) => {
      let parts = split_n(cut(reference, o + 3), "/", 3)
      if parts.length() == 3 {
        let key = segment(parts[2])
        return if key != "" { Some((key, None)) } else { None }
      }
    }
    None => ()
  }
  None
}

///|
/// `/\/w\/([^/\s]+)\/s\/([^/?#\s]+)\/chats\//u`: its workspace and station.
fn page_parts(reference : String) -> (String, String)? {
  let mut from = 0
  while cut(reference, from).find("/w/") is Some(at) {
    let start = from + at + 3
    let rest = cut(reference, start)
    let ws_end = stop_at(rest, c => c == '/' || js_space(c))
    let ws = cut(rest, 0, end=ws_end)
    let after = cut(rest, ws_end)
    if ws != "" && after.has_prefix("/s/") {
      let tail = cut(after, 3)
      let st_end = stop_at(tail, c => "/?#".contains_char(c) || js_space(c))
      let station = cut(tail, 0, end=st_end)
      if station != "" && cut(tail, st_end).has_prefix("/chats/") {
        return Some((ws, station))
      }
    }
    from = start - 2
  }
  None
}

///|
/// The station a link to a chat is on.
pub fn linked_station(reference : String) -> String? {
  if page_parts(reference) is Some((_, s)) {
    return Some(s)
  }
  guard reference.find("/o/") is Some(at) else { return None }
  let parts = split_n(cut(reference, at + 3), "/", 3)
  if parts.length() == 3 && parts[1] != "" {
    Some(parts[1])
  } else {
    None
  }
}

///|
/// The workspace a link to a chat names.
pub fn linked_workspace(reference : String) -> String? {
  if page_parts(reference) is Some((w, _)) {
    return Some(w)
  }
  guard reference.find("/o/") is Some(at) else { return None }
  let parts = split_n(cut(reference, at + 3), "/", 3)
  if parts.length() == 3 && parts[0] != "" {
    Some(parts[0])
  } else {
    None
  }
}

///|
/// str::splitn.
pub fn split_n(s : String, sep : String, n : Int) -> Array[String] {
  let parts = []
  let mut rest = s
  while parts.length() < n - 1 {
    guard rest.find(sep) is Some(at) else { break }
    parts.push(cut(rest, 0, end=at))
    rest = cut(rest, at + sep.length())
  }
  parts.push(rest)
  parts
}

///|
fn thread_of(v : Json) -> Json {
  get(v, "thread").unwrap_or(Json::null())
}

///|
fn sessions_of(v : Json) -> Array[String] {
  items(Some(v)).filter_map(m => str(m, "session"))
}

///|
/// The key a thread goes by where it is shared: its own session's, else its first agent's.
fn Storage::chat_key_of(self : Storage, t : Json) -> String raise {
  match str(t, "home") {
    Some(h) => h
    None => sessions_of(self.st.threads.thread_sessions(get(t, "id").unwrap_or(Json::null()))).get(0).unwrap_or("")
  }
}

///|
/// The chats session `key` is in, by the keys they are shared by.
fn Storage::chats_of(self : Storage, key : String) -> Array[String] raise {
  let out = [key]
  for t in items(Some(self.st.threads.session_threads(js(key), Json::null()))) {
    let c = self.chat_key_of(thread_of(t))
    if !out.contains(c) {
      out.push(c)
    }
  }
  out
}

///|
fn Storage::in_workspace(self : Storage, key : String, ws : String) -> Bool {
  self.st.hub.get_session(key) is Some(_) && self.st.hub.ws_of(Some(key)) == Some(ws)
}

///|
/// Whether workspace `ws` may reach session `key`'s chat (others.ts `reachable`).
pub async fn Storage::reachable(self : Storage, key : String, ws : String?, write? : Bool = false) -> Bool {
  guard ws is Some(w) else { return true }
  if self.in_workspace(key, w) {
    return true
  }
  let shared = []
  for c in self.chats_of(key) {
    let share = self.st.store.chat_share(js(c))
    if share is Null {
      continue
    }
    let to = items(get(share, "to")).iter().any(t => str(t, "workspace") == Some(w))
    if to && (!write || get(share, "write") is Some(True)) {
      shared.push(c)
    }
  }
  for c in shared {
    self.st.store.used_chat_share(js(c), [js(w)])
  }
  shared.length() > 0
}

///|
fn Storage::ws_of(self : Storage, key : String?) -> String? {
  self.st.hub.ws_of(key)
}

///|
/// Whether a thread is a chat of workspace `ws` (None: any).
pub async fn Storage::thread_in(self : Storage, thread : Json, ws : String?) -> Bool {
  guard ws is Some(w) else { return true }
  let keys = match str(thread, "home") {
    Some(h) => [h]
    None => sessions_of(self.st.threads.thread_sessions(get(thread, "id").unwrap_or(Json::null())))
  }
  if keys.length() == 0 {
    return self.ws_of(None) == Some(w)
  }
  for k in keys {
    if self.in_workspace(k, w) {
      return true
    }
  }
  false
}

///|
/// The workspace whose chats and stations session `key` reaches: its chat's; None on a station in no workspace.
pub async fn Storage::scope_of(self : Storage, key : String) -> String? {
  if self.st.hub.workspaces().length() == 0 {
    None
  } else {
    self.ws_of(Some(key))
  }
}

///|
/// The station transport as session `key` asks it (others.ts `peersOf`): None while there is none.
pub async fn Storage::peers_of(self : Storage, key : String) -> (async (String, Json) -> Json)? {
  if !(self.ask("hub.hasPeers", []) is True) {
    return None
  }
  let ws = self.scope_of(key)
  Some(async fn(station, request) {
    let request = match (ws, request) {
      (Some(w), Object(o)) => {
        let m = Map::new()
        m["workspace"] = js(w)
        for k, v in o {
          m[k] = v
        }
        Json::object(m)
      }
      _ => request
    }
    self.ask("peers.call", [js(station), request])
  })
}

///|
/// What another station answers with when it is from before a request.
pub fn from_before(refusal : String) -> Bool {
  refusal.contains("remote tasks are not enabled") || refusal.contains("task key")
}

///|
/// The other station of the workspace a chat's link is on; None when it is on this one.
pub async fn Storage::elsewhere(self : Storage, key : String, reference : String) -> String? {
  let here = match (self.st.hub.world.link)(key) {
    Some(link) => linked_station(link)
    None => None
  }
  match (here, linked_station(reference)) {
    (Some(h), Some(t)) if t != h => Some(t)
    _ => None
  }
}

///|
/// chat_read or session_history of a chat on another station of the workspace.
pub async fn Storage::read_afar(self : Storage, key : String, station : String, tool : String, args : Json) -> String {
  guard self.peers_of(key) is Some(call) else { raise failed("other stations cannot be reached from this one yet") }
  let given = []
  for k in ["chat", "before", "limit", "max_chars"] {
    match get(args, k) {
      Some(v) => given.push((k, v))
      None => ()
    }
  }
  let answer = call(station, jo([("method", js(read_method)), ("session", js(key)), ("tool", js(tool)), ("args", jo(given))])) catch {
    e => {
      let why = message_of(e)
      if is_kind(e, "Refused") && from_before(why) {
        raise failed("station \{station} is not updated yet: its chats cannot be read from here")
      }
      raise failed("not read from station \{station}: \{why}")
    }
  }
  guard str(answer, "text") is Some(text0) else { raise failed("station \{station} answered with nothing to read") }
  let mut text = text0
  let files : Array[Listed] = match get(answer, "files") {
    Some(Array(fs)) =>
      fs.filter_map(f => match (str(f, "path"), num(f, "size")) {
        (Some(path), Some(size)) => Some({ path, name: js_text(get(f, "name")) |> fn(n) { if get(f, "name") is (None | Some(Null)) { "" } else { n } }, size })
        _ => None
      })
    _ => []
  }
  let wanted = items(get(args, "fetch")).filter_map(p => if p is String(s) { Some(s) } else { None })
  let mut fetched = ""
  if files.length() > 0 || wanted.length() > 0 {
    let (here, left) = self.fetch_attachments(key, call, station, js_text(get(args, "chat")), files, wanted)
    for pair in here {
      text = text.replace_all(old="- \{pair.0} (", new="- \{pair.1} (")
    }
    let asked = wanted.filter_map(p => match here.iter().find_first(x => x.0 == p) {
      Some(x) => Some("\{p} → \{x.1}")
      None => None
    })
    if asked.length() > 0 {
      fetched += "\n(Fetched here: \{asked.join("; ")}.)"
    }
    if left.length() > 0 {
      fetched += "\n(Attachments left on station \{station}; fetch one with chat_read fetch=[its path]: \{left.join("; ")}.)"
    }
  }
  "(Read from station \{station}: give its chats' links, not their addresses or keys, to read more there.)\n\{text}\{fetched}"
}

///|
/// What another station's session reads here (`read_afar` there), from station `peer`.
pub async fn Storage::for_peer(self : Storage, peer : String, request : Json, ws : String?) -> Json {
  let tool = get(request, "tool")
  let args = match get(request, "args") {
    Some(Object(_) as a) => a
    _ => jo([])
  }
  let from = str(request, "session").unwrap_or("")
  match str(args, "chat") {
    Some(c) if js_trim(c) != "" => ()
    _ => raise failed("chat is required")
  }
  match tool {
    Some(String("chat_read")) => {
      let seen = []
      let text = self.chat_read("\{peer}/\{from}", args, Some(seen), ws)
      jo([
        ("text", js(text)),
        ("files", ja(seen.map(a => jo([("path", get(a, "path").unwrap_or(Json::null())), ("name", get(a, "name").unwrap_or(Json::null())), ("size", get(a, "size").unwrap_or(Json::null()))])))),
      ])
    }
    Some(String("session_history")) => jo([("text", js(self.session_history(args, ws)))])
    t => raise failed("cannot read with \{match t { None => "undefined"; Some(v) => v.stringify() }}")
  }
}

///|
/// The chats a session.* request of another station reads or writes in (others.ts `chatsTouched`).
pub async fn Storage::chats_touched(self : Storage, request : Json) -> Array[String] {
  let of_session = fn(key : String) raise {
    let out = []
    for t in items(Some(self.st.threads.session_threads(js(key), Json::null()))) {
      out.push(self.chat_key_of(thread_of(t)))
    }
    out
  }
  match str(request, "method") {
    Some("session.read") => {
      let chat = match get(request, "args") {
        Some(a) => js_text(get(a, "chat")) |> fn(t) { if get(a, "chat") is (None | Some(Null)) { "" } else { t } }
        None => ""
      }
      let what = self.named(chat, None)
      if str(request, "tool") == Some("chat_read") {
        let t = match what {
          Thread(t) => t
          Session(k, _) => thread_of(self.session_thread_of(k))
        }
        return [self.chat_key_of(t)]
      }
      match what {
        Session(k, _) => of_session(k)
        Thread(t) => [self.chat_key_of(t)]
      }
    }
    Some("session.file") => {
      let chat = match get(request, "chat") {
        None | Some(Null) => ""
        v => js_text(v)
      }
      match self.named(chat, None) {
        Session(k, _) => of_session(k)
        Thread(t) => [self.chat_key_of(t)]
      }
    }
    Some("session.put") | Some("session.message") => {
      let to = str(request, "to").unwrap_or("")
      if self.session(to) is None {
        return []
      }
      [self.chat_key_of(thread_of(self.session_thread_of(to)))]
    }
    _ => []
  }
}

///|
/// Text cut to `max` characters, saying how much was left out.
fn cut_chars(text : String, max : Int) -> String {
  let chars = text.to_array()
  if chars.length() <= max {
    text
  } else {
    "\{String::from_array(chars[:max].to_array())}… (\{chars.length() - max} more characters)"
  }
}

///|
/// One-line text: a title or a message's start, as a list shows it.
fn one_line(text : String, max : Int) -> String {
  let words = []
  let word = StringBuilder::new()
  let mut any = false
  for c in text {
    if js_space(c) {
      if any {
        words.push(word.to_string())
        word.reset()
        any = false
      }
    } else {
      word.write_char(c)
      any = true
    }
  }
  if any {
    words.push(word.to_string())
  }
  cut_chars(words.join(" "), max)
}

///|
/// Execution history entries as the agent reads them, numbered as the pages number them.
pub fn format_steps(start : Int, entries : Array[Json], max_chars : Int) -> String {
  entries
  .mapi((i, e) => {
    let kind = str(e, "kind").unwrap_or("")
    let what = if kind == "tool_call" && str(e, "tool") is Some(tool) {
      "tool_call \{tool}"
    } else if kind == "tool_result" && get(e, "ok") is Some(False) {
      "tool_result (error)"
    } else {
      kind
    }
    let sub = if get(e, "subagent") is Some(True) { " subagent" } else { "" }
    let at = match get(e, "at") {
      Some(Null) | None => ""
      v => " \{js_text(v)}"
    }
    "#\{start + i}\{at} \{what}\{sub}:\n\{cut_chars(js_trim(str(e, "text").unwrap_or("")), max_chars)}"
  })
  .join("\n\n")
}

///|
/// What a reference names on this station (others.ts `named`), of the chats workspace `ws` reaches.
pub async fn Storage::named(self : Storage, given : String, ws : String?, write? : Bool = false) -> Named {
  let reference = js_trim(given)
  if reference == "" {
    raise failed("chat is required: a chat's link, a thread address (CHANNEL/THREAD_TS) or a session key; chat_list lists them")
  }
  match linked_session(reference) {
    Some((key, entry)) => {
      let there = linked_workspace(reference)
      let known = self.session(key) is Some(_)
      if known && !self.reachable(key, ws) && there is Some(t) && Some(t) != ws {
        if ws is Some(w) {
          for c in self.chats_of(key) {
            if self.st.store.chat_share_lapsed(js(c), ja([js(w)])) {
              raise failed("\{reference} is a chat of another workspace: \{lapsed}")
            }
          }
        }
        raise failed("\{reference} is a chat of another workspace: that chat is not shared with your workspace")
      }
      if !known || !self.reachable(key, ws) {
        raise failed("\{reference} names session \{key}, which is not on this station (it may be another station's, or deleted)")
      }
      if !self.reachable(key, ws, write~) {
        raise failed("\{reference} is shared with your workspace to read only: nothing can be sent to it")
      }
      return Session(key, entry)
    }
    None => ()
  }
  match parse_thread_address(reference) {
    Some((channel, ts)) => {
      for t in items(Some(self.st.threads.threads_at(js(channel), js(ts)))) {
        if self.thread_in(t, ws) {
          return Thread(t)
        }
      }
      raise failed("no conversation \{reference} on this station")
    }
    None => ()
  }
  if self.session(reference) is Some(_) && self.reachable(reference, ws, write~) {
    return Session(reference, None)
  }
  raise failed("\{quoted(reference)} is not a chat of this station: give a chat's link, a thread address (CHANNEL/THREAD_TS) or a session key; chat_list lists them")
}

///|
/// The conversation a session is best read in: its own chat on the pages, else the one it last heard from.
pub async fn Storage::session_thread_of(self : Storage, key : String) -> Json {
  let home = self.st.threads.session_home_thread(js(key))
  if !nullish(Some(home)) {
    return home
  }
  let latest = self.with_threads(t => t.latest_thread(js(key)))
  if nullish(Some(latest)) {
    raise failed("session \{key} has no conversation yet")
  }
  latest
}

///|
fn limit_arg(v : Json?, low : Double, high : Double, fallback : Double) -> Double {
  match v {
    None => fallback
    Some(x) =>
      match js_number(x) {
        None => fallback
        Some(n) => if n.is_nan() { 0.0 } else { clamp_trunc(n, low, high) }
      }
  }
}

///|
async fn Storage::resolve_creator(self : Storage, key : String, raw : String) -> String {
  let s = js_trim(raw)
  if s == "" {
    return ""
  }
  if s.to_lower() == "me" {
    if key == "" {
      return ""
    }
    let from_thread : String? = (try Some(self.session_thread_of(key)) catch { _ => None }).bind(st => str(thread_of(st), "createdBy"))
    let creator = match from_thread {
      Some(c) if c != "" => Some(c)
      _ => self.session(key).bind(row => str(row, "createdBy"))
    }
    guard creator is Some(c) && c != "" else {
      raise failed("cannot determine who started this chat: pass an email in created_by")
    }
    return c
  }
  s
}

///|
async fn Storage::chat_list_here(self : Storage, key : String, args : Json, ws : String?) -> String {
  let limit = match get(args, "limit") {
    None => 20
    Some(x) =>
      match js_number(x) {
        None => 20
        Some(n) => if n.is_nan() { 0 } else { clamp_trunc(n, 1.0, 100.0).to_int() }
      }
  }
  let query = match get(args, "query") {
    None => ""
    Some(q) => js_trim(js_string(q)).to_lower()
  }
  let model = match get(args, "model") {
    None => ""
    Some(m) => js_trim(js_string(m)).to_lower()
  }
  let created_by = match get(args, "created_by") {
    None => ""
    Some(c) => self.resolve_creator(key, js_string(c)).to_lower()
  }
  let archived : Bool? = match get(args, "archived") {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
  let has_filter = model != "" || created_by != "" || !(archived is None)
  let filter_json : Json = if has_filter {
    let fs : Array[(String, Json)] = []
    if model != "" { fs.push(("model", js(model))) }
    if created_by != "" { fs.push(("createdBy", js(created_by))) }
    if archived is Some(a) { fs.push(("archived", jb(a))) }
    jo(fs)
  } else {
    Json::null()
  }
  let home = self.ws_of(None)
  let has = async fn(name : String) { self.ask("hub.has", [js(name)]) is True }
  let listed : Json? = if query == "" && !has_filter {
    if has("recentChatList") {
      Some(self.ask("hub.recentChatList", [jopt(ws), jopt(home), ji(limit)]))
    } else if !has("threadList") {
      Some(self.st.threads.recent_chat_list(jopt(ws), jopt(home), ji(limit)))
    } else {
      None
    }
  } else if has("searchChatList") {
    Some(
      self.ask(
        "hub.searchChatList",
        if has_filter { [jopt(ws), jopt(home), ji(limit), js(query), filter_json] } else { [jopt(ws), jopt(home), ji(limit), js(query)] },
      ),
    )
  } else if !has("threadList") {
    Some(
      if has_filter {
        self.st.threads.search_chat_list(jopt(ws), jopt(home), ji(limit), js(query), filter=filter_json)
      } else {
        self.st.threads.search_chat_list(jopt(ws), jopt(home), ji(limit), js(query))
      },
    )
  } else {
    None
  }
  let listed = match listed {
    Some(l) if !nullish(Some(l)) => Some(l)
    _ => None
  }
  let rows = match listed {
    Some(l) if get(l, "sessions") is Some(Array(_)) => items(get(l, "sessions"))
    _ => self.st.store.list_sessions()
  }
  let sessions : Map[String, Json] = {}
  for s in rows {
    if str(s, "key") is Some(k) {
      sessions[k] = s
    }
  }
  let ws_of_row = (k : String) => match sessions.get(k) {
    Some(s) => match get(s, "ws") { Some(String(w)) => Some(w); _ => home }
    None => home
  }
  let in_ws = (k : String) => ws_of_row(k) == ws
  let threads = match listed {
    Some(l) if get(l, "threads") is Some(Array(ts)) => ts.copy()
    _ => {
      let all = if has("threadList") {
        items(Some(self.ask("hub.threadList", [])))
      } else {
        items(Some(self.st.threads.list_threads(js(""), Json::null(), Json::null(), js("none"))))
      }
      all.filter(t => {
        let th = thread_of(t)
        let ms = sessions_of(get(t, "sessions").unwrap_or(ja([])))
        ws is None ||
        (match str(th, "home") {
          Some(h) => in_ws(h)
          None => if ms.length() == 0 { home == ws } else { ms.iter().any(in_ws) }
        })
      })
    }
  }
  let when = (t : Json) => match get(t, "lastMessage") {
    Some(Object(_) as m) => num(m, "createdAt").unwrap_or(0.0)
    _ => num(thread_of(t), "createdAt").unwrap_or(0.0)
  }
  threads.sort_by((a, b) => when(b).compare(when(a)))
  let lines = []
  let mut matched = match listed {
    Some(l) => num(l, "total").unwrap_or(0.0).to_int()
    None => 0
  }
  for t in threads {
    let th = thread_of(t)
    let members = sessions_of(get(t, "sessions").unwrap_or(ja([])))
    let titles = [str(th, "title"), str(th, "autoTitle"), str(t, "firstText")]
    for m in members {
      titles.push(match sessions.get(m) { Some(s) => str(s, "title"); None => None })
    }
    let titles = titles.filter_map(x => x)
    let last = match get(t, "lastMessage") {
      Some(Object(_) as m) => str(m, "text").unwrap_or("")
      _ => ""
    }
    if listed is None {
      if archived is Some(want_archived) {
        let hidden = !nullish(get(th, "hiddenAt"))
        let home_archived = match str(th, "home") {
          Some(h) => match sessions.get(h) { Some(s) => !nullish(get(s, "archivedAt")); None => false }
          None => false
        }
        if (hidden || home_archived) != want_archived {
          continue
        }
      }
      if model != "" {
        if !members.iter().any(m => match sessions.get(m) { Some(s) => str(s, "model").unwrap_or("").to_lower().contains(model); None => false }) {
          continue
        }
      }
      if created_by != "" {
        let tc = str(th, "createdBy").unwrap_or("").to_lower()
        let ok = (tc != "" && tc.contains(created_by)) ||
          members.iter().any(m => match sessions.get(m) {
            Some(s) => {
              let c = str(s, "createdBy").unwrap_or("").to_lower()
              c != "" && c.contains(created_by)
            }
            None => false
          })
        if !ok {
          continue
        }
      }
      if query != "" {
        let haystack = "\{titles.join(" ")} \{last} \{members.join(" ")}".to_lower()
        if !haystack.contains(query) {
          continue
        }
      }
      matched += 1
    }
    if lines.length() >= limit {
      continue
    }
    let address = thread_address(str(th, "channel").unwrap_or(""), str(th, "threadTs").unwrap_or(""))
    let place = if str(th, "surface") == Some(stillfail_surface) { "still.fail chat" } else { "Slack thread" }
    let title = if titles.length() > 0 { one_line(titles[0], 80) } else { "(untitled)" }
    let agents = members.map(m => {
      let you = if m == key { " (you)" } else { "" }
      let archived_tag = match sessions.get(m) {
        Some(s) => if nullish(get(s, "archivedAt")) { "" } else { " archived" }
        None => ""
      }
      "\{m}\{you}\{archived_tag}"
    })
    let at = iso(when(t))
    let hidden = if nullish(get(th, "hiddenAt")) { "" } else { ", archived" }
    let mut entry = "- \{address} (\{place}\{hidden}) \"\{title}\"\n  agents: \{if agents.length() == 0 { "none" } else { agents.join(", ") }}; last message \{at}"
    if last != "" {
      entry += ": \{one_line(last, 120)}"
    }
    let run_info : Array[String] = []
    for m in members {
      if sessions.get(m) is Some(s) {
        if str(s, "runtime") is Some(rt) && rt != "" {
          let m_name = match str(s, "model") { Some(mm) if mm != "" => "/\{mm}"; _ => "" }
          let eff = match str(s, "effort") { Some(ef) if ef != "" => " (\{ef})"; _ => "" }
          let running_tag = match get(s, "running") { Some(True) => " running"; Some(Number(n, ..)) if n != 0.0 => " running"; _ => "" }
          run_info.push("\{rt}\{m_name}\{eff}\{running_tag}")
        }
      }
    }
    let creator : String? = match str(th, "createdBy") {
      Some(c) if c != "" => Some(c)
      _ => {
        let mut found : String? = None
        for m in members {
          if found is None {
            if sessions.get(m) is Some(s) {
              if str(s, "createdBy") is Some(c) && c != "" {
                found = Some(c)
              }
            }
          }
        }
        found
      }
    }
    let details : Array[String] = []
    if run_info.length() > 0 {
      details.push("model: \{run_info.join(", ")}")
    }
    if creator is Some(c) {
      details.push("by: \{c}")
    }
    if details.length() > 0 {
      entry += "\n  \{details.join("; ")}"
    }
    if members.length() > 0 {
      match (self.st.hub.world.link)(members[0]) {
        Some(link) if link != "" => entry += "\n  link: \{link}"
        _ => ()
      }
    }
    lines.push(entry)
  }
  let outside = if has_filter {
    []
  } else {
    items(Some(self.ask("hub.outsideChats", [jopt(ws)]))).filter(c => {
      query == "" ||
      "\{str(c, "title").unwrap_or("")} \{str(c, "workspaceName").unwrap_or("")} \{str(c, "link").unwrap_or("")}".to_lower().contains(query)
    })
  }
  let shown = outside[:if outside.length() < limit { outside.length() } else { limit }].to_array()
  let shared = shown.map(c => {
    let can = if get(c, "write") is Some(True) { "you may send to it" } else { "read only" }
    "- \{str(c, "link").unwrap_or("")} (shared from workspace \"\{one_line(str(c, "workspaceName").unwrap_or(""), 40)}\", \{can}) \"\{one_line(str(c, "title").unwrap_or(""), 80)}\""
  })
  let shared_more = if outside.length() > shared.length() { "\n(\{outside.length() - shared.length()} more shared; narrow query)" } else { "" }
  let shared_part = if shared.length() > 0 {
    "\n\nShared with this workspace by other workspaces (read with chat_read, by the link):\n\{shared.join("\n")}\{shared_more}"
  } else {
    ""
  }
  if lines.length() == 0 {
    let empty = if query == "" && !has_filter {
      "No conversations on this station."
    } else if query != "" && !has_filter {
      "No conversation matches \{quoted(query)}."
    } else {
      "No conversation matches the filter."
    }
    return empty + shared_part
  }
  let more = if matched > lines.length() { "\n(\{matched - lines.length()} more; raise limit or narrow query)" } else { "" }
  "\{lines.join("\n")}\{more}\{shared_part}"
}

///|
/// chat_list: the station's conversations of session `key`'s workspace, or another/all stations of the workspace.
pub async fn Storage::chat_list(self : Storage, key : String, args : Json) -> String {
  let ws = self.scope_of(key)
  let station = match get(args, "station") {
    Some(String(s)) => js_trim(s)
    _ => ""
  }
  if station == "" {
    return self.chat_list_here(key, args, ws)
  }
  let resolved_creator = match get(args, "created_by") {
    None => ""
    Some(c) => self.resolve_creator(key, js_string(c))
  }
  let fwd : Array[(String, Json)] = []
  if get(args, "query") is Some(v) { fwd.push(("query", v)) }
  if get(args, "model") is Some(v) { fwd.push(("model", v)) }
  if resolved_creator != "" { fwd.push(("created_by", js(resolved_creator))) }
  if get(args, "archived") is Some(v) && (v is True || v is False) { fwd.push(("archived", v)) }
  if get(args, "limit") is Some(v) { fwd.push(("limit", v)) }
  let forwarded = jo(fwd)
  let here = (self.st.hub.world.link)(key).bind(linked_station)
  if here == Some(station) {
    return self.chat_list_here(key, forwarded, ws)
  }
  guard self.peers_of(key) is Some(call) else {
    if station.to_lower() == "all" {
      return self.chat_list_here(key, forwarded, ws)
    }
    raise failed("other stations cannot be reached from this one yet: leave station out to list this station")
  }
  let roster = call("", jo([("method", js("peers"))]))
  let stations : Array[(String, String)] = []
  for s in items(get(roster, "stations")) {
    if str(s, "id") is Some(id) && id != "" {
      let name = match str(s, "name") { Some(n) if n != "" => n; _ => id }
      stations.push((id, name))
    }
  }
  if station.to_lower() == "all" {
    let targets = if stations.iter().any(p => Some(p.0) == here) {
      stations
    } else {
      [(here.unwrap_or(""), "this station"), ..stations]
    }
    let parts : Array[String] = []
    for t in targets {
      let is_here = t.0 == "" || Some(t.0) == here
      let header = if is_here { "## \{t.1} (this station)" } else { "## \{t.1}" }
      if is_here {
        parts.push("\{header}\n\{self.chat_list_here(key, forwarded, ws)}")
      } else {
        let out = try {
          let answer = call(t.0, jo([("method", js(list_method)), ("session", js(key)), ("args", forwarded)]))
          match str(answer, "text") {
            Some(txt) => "\{header}\n\{txt}"
            None => "\{header}\nNot listed: station answered without a list"
          }
        } catch {
          e => {
            let why = message_of(e)
            if is_kind(e, "Refused") && from_before(why) {
              "\{header}\nNot listed: station is not updated yet"
            } else {
              "\{header}\nNot listed: \{why}"
            }
          }
        }
        parts.push(out)
      }
    }
    return parts.join("\n\n")
  }
  let lower = station.to_lower()
  let found = match stations.iter().find_first(p => p.0 == station) {
    Some(p) => Some(p)
    None => stations.iter().find_first(p => p.1.to_lower() == lower)
  }
  guard found is Some((id, name)) else {
    let names = stations.map(p => p.1)
    let suffix = if names.length() > 0 { "; its stations: \{names.join(", ")}" } else { "" }
    raise failed("no station \{station} in this workspace\{suffix}")
  }
  if Some(id) == here {
    return self.chat_list_here(key, forwarded, ws)
  }
  let answer = call(id, jo([("method", js(list_method)), ("session", js(key)), ("args", forwarded)])) catch {
    e => {
      let why = message_of(e)
      if is_kind(e, "Refused") && from_before(why) {
        raise failed("station \{name} is not updated yet: its chats cannot be listed from here")
      }
      raise failed("not listed from station \{name}: \{why}")
    }
  }
  guard str(answer, "text") is Some(text) else {
    raise failed("station \{name} answered without a list")
  }
  text
}

///|
pub async fn Storage::list_for_peer(self : Storage, request : Json, ws : String?) -> Json {
  let args = match get(request, "args") {
    Some(Object(_) as a) => a
    _ => jo([])
  }
  jo([("text", js(self.chat_list_here("", args, ws)))])
}

///|
/// chat_read: the messages of any conversation of the station that workspace `ws` reaches. `seen` gets the attachments
/// of the messages given.
pub async fn Storage::chat_read(self : Storage, key : String, args : Json, seen : Array[Json]?, ws : String?) -> String {
  let reference = match get(args, "chat") {
    None => ""
    Some(c) => js_string(c)
  }
  let what = self.named(reference, ws)
  let mut note = ""
  let (thread, connect) = match what {
    Thread(t) => {
      let members = items(Some(self.st.threads.thread_sessions(get(t, "id").unwrap_or(Json::null()))))
      (t, match members.get(0) { Some(m) => str(m, "connect").unwrap_or(""); None => "" })
    }
    Session(k, _) => {
      let found = self.session_thread_of(k)
      let ft = thread_of(found)
      let recent = self.with_threads(t => t.recent_session_threads(js(k), Json::null()))
      let rest = items(get(recent, "threads")).filter(t => get(thread_of(t), "id") != get(ft, "id"))
      let others = self.st.hub.threads_told_of(k, recent=(rest, get(recent, "more") is Some(True)))
      if others.length() > 0 {
        note = "\n(Session \{k} also takes part in \{others.join(", ")}; read them with chat_read chat=<address>.)"
      }
      (ft, str(found, "connect").unwrap_or(""))
    }
  }
  let address = thread_address(str(thread, "channel").unwrap_or(""), str(thread, "threadTs").unwrap_or(""))
  let read = self.ask("fn.threadHistory", [js(key), thread, js(connect), js(address), args, jb(seen is Some(_))])
  match seen {
    Some(out) => for a in items(get(read, "seen")) { out.push(a) }
    None => ()
  }
  let text = str(read, "text").unwrap_or("")
  let agents = sessions_of(self.st.threads.thread_sessions(get(thread, "id").unwrap_or(Json::null())))
  let link = if agents.length() > 0 { (self.st.hub.world.link)(agents[0]) } else { None }
  let linked = match link {
    Some(l) if l != "" => " (\{l})"
    _ => ""
  }
  "Conversation \{address}\{linked}; its agents: \{if agents.length() == 0 { "none" } else { agents.join(", ") }}.\n\{text}\{note}"
}

///|
/// session_history: what a session's agent did (its execution history, as the pages show it).
pub async fn Storage::session_history(self : Storage, args : Json, ws : String?) -> String {
  let reference = match get(args, "chat") {
    None => ""
    Some(c) => js_string(c)
  }
  let (session, entry) = match self.named(reference, ws) {
    Session(k, e) => (k, e)
    Thread(t) => {
      let agents = sessions_of(self.st.threads.thread_sessions(get(t, "id").unwrap_or(Json::null())))
      if agents.length() == 0 {
        raise failed("\{reference} has no agent, so no execution history")
      }
      if agents.length() > 1 {
        raise failed("\{reference} has several agents; give one of them as chat: \{agents.join(", ")}")
      }
      (agents[0], None)
    }
  }
  let limit = limit_arg(get(args, "limit"), 1.0, 200.0, 40.0)
  let max_chars = limit_arg(get(args, "max_chars"), 100.0, 4000.0, 1500.0)
  let given = match get(args, "before") {
    None => None
    Some(v) => js_number(v)
  }
  let before = match given {
    Some(g) => if g.is_nan() { 0.0 } else { (if g < 0.0 { 0.0 } else { g }).floor() }
    None =>
      match entry {
        Some(e) => e.to_double() + 1.0 + (limit / 2.0).floor()
        None => 9007199254740991.0
      }
  }
  guard self.session(session) is Some(row) else { raise failed("unknown session \{session}") }
  let read = self.ask("live.page", [js(session), jn(before), jn(limit)])
  if nullish(Some(read)) || num(read, "end") == Some(0.0) {
    return "Session \{session} has no execution history yet."
  }
  let start = num(read, "start").unwrap_or(0.0).to_int()
  let entries = items(get(read, "entries"))
  let total = num(read, "end").unwrap_or(0.0)
  if entries.length() == 0 {
    return "Session \{session} has \{num_text(total)} entries of execution history; none before #\{num_text(before)}."
  }
  let model = match str(row, "model") {
    Some(m) => ", \{m}"
    None => ""
  }
  let older = if start > 0 { " Older ones: before=\{start}." } else { "" }
  "Session \{session} (\{str(row, "runtime").unwrap_or("")}\{model}): entries #\{start}–#\{start + entries.length() - 1} of \{num_text(total)}.\{older}\n\n\{format_steps(start, entries, max_chars.to_int())}"
}
