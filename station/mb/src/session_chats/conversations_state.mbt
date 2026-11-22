// chat_state, chat_leave, chat_history and slack_api (station/src/sessions/conversations.ts).

///|
let min_wait_seconds : Double = 10.0

///|
let max_wait_seconds : Double = 3600.0

///|
/// args.ts `jsNumber`: a number, or a string holding one.
pub fn js_number(v : J) -> Double? {
  match v {
    Num(d) => Some(d)
    Str(u) => {
      let t = trim(@jsjson.sanitize_str(u))
      let low = lower(t)
      let body = if starts(low, "+") || starts(low, "-") { slice(low, 1) } else { low }
      if body == "inf" || body == "infinity" {
        return Some(if starts(t, "-") { -@double.infinity } else { @double.infinity })
      }
      if body == "nan" {
        return Some(@double.not_a_number)
      }
      let digits = (s : String) => s != "" && all_digits(s)
      // /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/
      let (mant, exp) = {
        let e = index_of_any(body, "eE")
        if e < 0 {
          (body, None)
        } else {
          (slice(body, 0, b=e), Some(slice(body, e + 1)))
        }
      }
      let ok_exp = match exp {
        None => true
        Some(x) => {
          let y = if starts(x, "+") || starts(x, "-") { slice(x, 1) } else { x }
          digits(y)
        }
      }
      let dot = index_of(mant, ".")
      let ok_mant = if dot < 0 {
        digits(mant)
      } else {
        let a = slice(mant, 0, b=dot)
        let b = slice(mant, dot + 1)
        (digits(a) && (b == "" || all_digits(b))) || (a == "" && digits(b))
      }
      if ok_mant && ok_exp {
        let text = normalize_number(if starts(t, "+") { slice(t, 1) } else { t })
        Some(num_or_nan(@jsjson.parse(text) catch { _ => J::Null }))
      } else {
        None
      }
    }
    _ => None
  }
}

///|
fn num_or_nan(v : J) -> Double {
  match v {
    Num(d) => d
    _ => @double.not_a_number
  }
}

///|
/// A number JSON.parse reads as JavaScript's Number() would ("1." and ".5" made "1.0" and "0.5").
fn normalize_number(t : String) -> String {
  let neg = starts(t, "-")
  let mut s = if neg { slice(t, 1) } else { t }
  if starts(s, ".") {
    s = "0" + s
  }
  let e = index_of_any(s, "eE")
  let (m, rest) = if e < 0 { (s, "") } else { (slice(s, 0, b=e), slice(s, e)) }
  let m2 = if ends(m, ".") { m + "0" } else { m }
  // leading zeros JSON refuses
  let mut k = 0
  while k + 1 < m2.length() && m2.unsafe_charcode_at(k) == '0' && m2.unsafe_charcode_at(k + 1) != '.' {
    k += 1
  }
  (if neg { "-" } else { "" }) + slice(m2, k) + rest
}

///|
fn all_digits(s : String) -> Bool {
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    if c < '0' || c > '9' {
      return false
    }
  }
  true
}

///|
fn index_of_any(s : String, cs : String) -> Int {
  for i in 0..<s.length() {
    if cs.contains_char(s.unsafe_charcode_at(i).unsafe_to_char()) {
      return i
    }
  }
  -1
}

///|
/// What a state recorded with chat_state is about.
async fn state_about(w : World, key : String, kind : J, args : J) -> J {
  let threads = arr_of(at(Some(w.with_threads_j(t => t.recent_session_threads(Json::string(key), Json::null()))), "threads")).unwrap_or([])
  match about_ts(args) {
    Some(ts) => {
      for t in threads {
        let m = message_for_about(w, key, at(at(Some(t), "thread"), "id").unwrap_or(Null), ts, kind_kind(kind) == "need_help")
        if !(m is Null) {
          return m
        }
      }
      raise fail_("about must be the ts of a message in one of your conversations (or leave it out), got \{ts}")
    }
    None => ()
  }
  if kind_kind(kind) != "need_help" {
    return Null
  }
  let pending = []
  for t in threads {
    let p = w.with_threads_j(th => th.pending_card(at(at(Some(t), "thread"), "id").unwrap_or(Null).to_json()))
    match at_i(Some(p), 0) {
      Some(x) if !(x is Null) => pending.push(x)
      _ => ()
    }
  }
  let order = pending.mapi((i, p) => (i, p))
  order.sort_by((a, b) => {
    let x = num_of(at(Some(a.1), "createdAt")).unwrap_or(0.0)
    let y = num_of(at(Some(b.1), "createdAt")).unwrap_or(0.0)
    if x < y {
      -1
    } else if x > y {
      1
    } else {
      a.0 - b.0
    }
  })
  match order.last() {
    Some((_, last)) => ja([at(Some(last), "thread").unwrap_or(Null), at(Some(last), "n").unwrap_or(Null), at(Some(last), "ts").unwrap_or(Null)])
    None => Null
  }
}

///|
/// chat_state: how this turn ends, recorded without posting.
pub async fn chat_state(w : World, key : String, args : J) -> String {
  let mut kind = J::Null
  let mut words = J::Null
  let mut watch = false
  let kind_arg = at(Some(args), "kind")
  if str_of(kind_arg) == Some("waiting") {
    let seconds = match at(Some(args), "seconds") {
      None => None
      Some(v) => js_number(v)
    }
    guard seconds is Some(seconds) else {
      raise fail_("seconds is required for waiting: how long until the work brings you back")
    }
    let what = match at(Some(args), "for") {
      None => ""
      Some(v) => trim(js_string(v))
    }
    if what == "" {
      raise fail_("for is required for waiting: what you wait for, in a few words people read")
    }
    match at(Some(args), "watch") {
      None | Some(Bool(_)) => ()
      _ => raise fail_("watch must be true or false")
    }
    watch = at(Some(args), "watch") is Some(Bool(true))
    if watch && !(w.with_threads_j(t => t.has_session_active_watch(Json::string(key))) is Bool(true)) {
      raise fail_(
        "watch: true is for waiting on a watch of yours that runs (job_start with watch); none does: leave it out, or start the watch first",
      )
    }
    let whole = if seconds.is_nan() { 0.0 } else { js_trunc(@cmp.maximum(0.0, seconds)) }
    kind = jo([("kind", js("waiting")), ("seconds", jn(@cmp.minimum(max_wait_seconds, @cmp.maximum(min_wait_seconds, whole))))])
    words = js(what)
  } else {
    let given = hub_ok(() => @session_hub.state_arg(opt_json(kind_arg)))
    guard given is Some((k_json, said)) else {
      raise fail_("kind is required")
    }
    if said == "decision" {
      raise fail_(
        "need_decision is posted with chat_post: the question in the text, its options in a card; then the turn ends need_human",
      )
    }
    kind = @jsjson.JValue::of_json(k_json)
    words = need_arg_of(args, k_json, said)
  }
  let ts = about_ts(args)
  let need_help = kind_kind(kind) == "need_help"
  let checking_question = need_help && ts is Some(_)
  let checking_default = need_help && ts is None
  let question_actor = if checking_question || checking_default { actor_id(w, key) } else { J::Null }
  let question_turn = if !(question_actor is Null) { w.actor(key, "currentTurnId", []) } else { J::Null }
  let recent = async fn() { recent_thread_ids(w, key) }
  let about = if checking_question {
    let a = question_for_about(w, key, recent, ts.unwrap())
    if a is Null {
      raise fail_("about must be the ts of a message in one of your conversations (or leave it out), got \{ts.unwrap()}")
    }
    a
  } else if checking_default {
    pending_for_state(w, key, recent)
  } else {
    state_about(w, key, kind, args)
  }
  let block = str_of(kind_arg) == Some("block")
  if need_help && about is Null && !block {
    raise fail_(need_visible_question)
  }
  if checking_question {
    if !(question_actor is Null) && !(question_turn is Null) {
      let t = ts.unwrap()
      let ok = jeq(actor_id(w, key), question_actor) &&
        !(about is Null) &&
        record_question_for_turn(
          w,
          key,
          question_turn,
          kind,
          words,
          about,
          watch,
          recent,
          t,
          "about must be the ts of a message in one of your conversations (or leave it out), got \{t}",
        )
      if !ok {
        raise fail_("the turn ended while checking its question; its state was not recorded")
      }
    }
  } else if checking_default {
    if !(question_actor is Null) && !(question_turn is Null) {
      if !record_pending_for_turn(w, key, question_actor, question_turn, kind, words, about, watch, recent, !block) {
        raise fail_("the turn ended while checking its question; its state was not recorded")
      }
    }
  } else if !(actor_id(w, key) is Null) {
    if !(words is Null) {
      if kind_kind(kind) == "waiting" {
        w.actor(key, "waitFor", [words, jb(watch)]) |> ignore
      } else {
        w.actor(key, "need", [words]) |> ignore
      }
    }
    w.actor(key, "about", [about]) |> ignore
    let ok = w.actor(key, "declare", [kind])
    if !(ok is Bool(true)) {
      raise fail_("the turn ended before its state was recorded; its state was not recorded")
    }
  }
  if kind_kind(kind) == "all_done" {
    suggest_archive(w, key)
  }
  if kind_kind(kind) != "waiting" {
    return "Recorded state \{said_as(kind)}."
  }
  if watch {
    "Recorded state waiting on your watch: its notices, its end or a message bring you back."
  } else {
    "Recorded state waiting: you are asked again in \{num_text(num_of(at(Some(kind), "seconds")).unwrap_or(0.0))} seconds unless something brings you back first."
  }
}

///|
/// chat_leave: the session stops hearing a Slack, Feishu or group thread until someone mentions it there.
pub async fn chat_leave(w : World, key : String, args : J) -> String {
  let thread = target(w, key, at(Some(args), "to"))
  let to = js_string(at(Some(args), "to").unwrap_or(Null))
  let row = at(Some(thread), "thread")
  if str_of(at(row, "surface")) == Some(stillfail_surface) {
    raise fail_("\{to} is a still.fail chat: it cannot be left. Only Slack, Feishu and group threads can.")
  }
  ignore(w.with_threads_j(t => t.leave_thread(at(row, "id").unwrap_or(Null).to_json(), Json::string(key))))
  "Left \{to}: its messages no longer reach you until someone mentions you there; chat_history still reads it and chat_post still posts there."
}

///|
/// chat_history: earlier messages of one of the session's conversations.
pub async fn chat_history(w : World, key : String, args : J) -> String {
  let thread = target(w, key, at(Some(args), "to"))
  let to = match at(Some(args), "to") {
    None => ""
    Some(v) => js_string(v)
  }
  thread_history(
    w,
    key,
    at(Some(thread), "thread").unwrap_or(Null),
    str_of(at(Some(thread), "connect")).unwrap_or(""),
    to,
    args,
    None,
  )
}

///|
/// A thread's messages as chat_history and chat_read give them. `seen` gets the attachments of those given.
pub async fn thread_history(
  w : World,
  key : String,
  thread : J,
  connect : String,
  named : String,
  args : J,
  seen : Array[J]?,
) -> String {
  let given = match at(Some(args), "limit") {
    None => None
    Some(v) => js_number(v)
  }
  let limit = match given {
    Some(g) if g != 0.0 => if g.is_nan() { 0.0 } else { js_trunc(@cmp.minimum(200.0, @cmp.maximum(1.0, g))) }
    _ => 30.0
  }
  let before = match at(Some(args), "before") {
    Some(Str(u)) if u.length() > 0 => Some(@jsjson.sanitize_str(u))
    _ => None
  }
  let tid = at(Some(thread), "id").unwrap_or(Null)
  let b_json = match before { Some(s) => Json::string(s); None => Json::null() }
  let messages = w.with_db_j(db => @readops.chat_history_messages(db, { "thread": tid.to_json(), "before": b_json, "limit": Json::number(limit) }))
  guard messages is Arr(messages) else {
    raise fail_("no message \{match before { Some(b) => b; None => "null" }} in \{named}")
  }
  if messages.length() == 0 {
    return "No earlier messages."
  }
  match seen {
    Some(s) => for m in messages { for a in arr_of(at(Some(m), "attachments")).unwrap_or([]) { s.push(a) } }
    None => ()
  }
  let names : Array[(String, String)] = []
  for m in messages {
    if str_of(at(Some(m), "authorKind")) != Some("person") {
      continue
    }
    let author = str_of(at(Some(m), "author")).unwrap_or("")
    if names.iter().any(p => p.0 == author) {
      continue
    }
    match str_of(Some(w.ask("chatOf.userName", [js(connect), js(author)]))) {
      Some(name) => names.push((author, name))
      None => ()
    }
  }
  let cards : Map[Double, @agent_runtimes.HistoryCard] = Map([])
  let card_ns : Array[J] = []
  let ns = messages.map(m => at(Some(m), "n").unwrap_or(Null))
  for e in arr_of(Some(w.with_threads_j(t => t.message_page_entries(tid.to_json(), ja(ns).to_json())))).unwrap_or([]) {
    if str_of(at(Some(e), "kind")) != Some("message") {
      continue
    }
    let card = if !nullish(at(Some(e), "card")) {
      at(Some(e), "card").unwrap()
    } else if !nullish(at(Some(e), "options")) {
      jo([("type", js("options")), ("options", at(Some(e), "options").unwrap())])
    } else {
      J::Null
    }
    if !(card is Null) {
      if num_of(at(Some(e), "n")) is Some(n) {
        if !cards.contains(n) {
          card_ns.push(jn(n))
        }
        cards[n] = { card: Some(card), pending: false, chose: None }
      }
    }
  }
  if cards.length() > 0 {
    let pending = w.with_db_j(db => @readops.pending_card_number(db, tid.to_json()))
    if num_of(Some(pending)) is Some(p) && cards.get(p) is Some(entry) {
      cards[p] = { ..entry, pending: true }
    }
    for pair in arr_of(Some(w.with_threads_j(t => t.card_choices(tid.to_json(), ja(card_ns).to_json())))).unwrap_or([]) {
      let c = at_i(Some(pair), 1)
      let by = str_of(at(c, "by")).unwrap_or("")
      let name = str_of(Some(w.ask("chatOf.userName", [js(connect), js(by)])))
      let who = match name { Some(x) => "\{x} (\{by})"; None => by }
      if num_of(at_i(Some(pair), 0)) is Some(n) && cards.get(n) is Some(entry) {
        cards[n] = { ..entry, chose: Some((who, at(c, "option").unwrap_or(Null))) }
      }
    }
  }
  let surface = str_of(at(Some(thread), "surface")).unwrap_or("")
  @agent_runtimes.format_history(
    messages,
    surface,
    address_of_row(Some(thread)),
    key,
    names,
    cards~,
  )
}

///|
/// The Slack connect a session calls as when it names none.
pub async fn slack_connect_of(w : World, key : String, bot : String?) -> String {
  let session = w.store_get_session(key)
  let own = str_of(at(Some(session), "connect"))
  if bot is None && own is Some(o) && o != internal_connect {
    return o
  }
  let workspaces = w.with_hub(h => h.workspaces()).map(js)
  let home = if workspaces.length() > 0 { workspaces[0] } else { J::Null }
  let ws = jopt(w.with_hub(h => h.ws_of_arg((if session is Null { js(key) } else { session }).to_json())))
  let bots = []
  for c in arr_of(at(Some(w.config()), "connects")).unwrap_or([]) {
    if str_of(at(Some(c), "kind")) != Some("slack") || !(at(Some(c), "enabled") is Some(Bool(true))) {
      continue
    }
    let cws = match at(Some(c), "workspace") {
      None | Some(Null) => home
      Some(x) => x
    }
    if !jeq(cws, ws) {
      continue
    }
    let cid = str_of(at(Some(c), "id")).unwrap_or("")
    if !(cid == @session_hub.internal_connect || (w.require_live().hub.world.chat)(cid) is Some(_)) {
      continue
    }
    bots.push(c)
  }
  let id_of = (c : J) => str_of(at(Some(c), "id")).unwrap_or("")
  let bot_name = (c : J) => match str_of(at(at(Some(c), "slack"), "botName")) {
    Some(b) if b != "" => Some(b)
    _ => None
  }
  let named = (c : J) => match bot_name(c) {
    Some(b) => "\{id_of(c)} (\{b})"
    None => id_of(c)
  }
  match bot {
    Some(b) => {
      let wanted = lower(trim(b))
      match bots.search_by(c => lower(id_of(c)) == wanted || (match bot_name(c) { Some(n) => lower(n) == wanted; None => false })) {
        Some(i) => return id_of(bots[i])
        None => {
          let list = bots.map(named).join(", ")
          raise fail_("no Slack bot \{quoted(b)} here; bot is one of: \{if list == "" { "none" } else { list }}")
        }
      }
    }
    None => ()
  }
  if bots.length() == 1 {
    return id_of(bots[0])
  }
  let runtime = at(Some(session), "runtime").unwrap_or(Null)
  let bound = bots.filter(c => jeq(at(at(Some(c), "bind"), "runtime").unwrap_or(Null), runtime))
  if bound.length() == 1 {
    return id_of(bound[0])
  }
  if bots.length() == 0 {
    raise fail_("this station has no Slack bot in this chat's workspace")
  }
  raise fail_("this chat has no Slack bot of its own: give bot= one of: \{bots.map(named).join(", ")}")
}

///|
/// What withdrawing a card where no conversation began yet is told.
let withdraw_begun : String = "withdraw needs an existing CHANNEL/THREAD_TS conversation"

///|
/// The Feishu chat a chat_post's `to` names where it begins a conversation there (`oc_…`, a `/` after it allowed);
/// None for anything else (a conversation's CHANNEL/THREAD_TS among them).
fn feishu_chat_id(to : J?) -> String? {
  guard str_of(to) is Some(given) else { return None }
  let t = trim(given)
  let chat = if t.has_suffix("/") { t[:t.length() - 1].to_string() } else { t }
  guard chat.has_prefix("oc_") && chat.length() > 3 else { return None }
  for c in chat[3:] {
    if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
      return None
    }
  }
  Some(chat)
}

///|
/// The Feishu connect a session begins a conversation through: its own; else the one of a recent conversation of it;
/// else the station's Feishu bot in its workspace (with several, the one bound to its profile, its runtime and model,
/// or its runtime). Only one whose surface can begin a conversation.
async fn feishu_connect_of(w : World, key : String) -> String {
  let session = w.store_get_session(key)
  let connects = arr_of(at(Some(w.config()), "connects")).unwrap_or([])
  let usable = async fn(id : String) -> Bool {
    if id == "" || id == internal_connect {
      return false
    }
    let platform = str_of(Some(w.ask("hub.chatProp", [js(id), js("platform")])))
    let feishu = connects.iter().any(c => str_of(at(Some(c), "id")) == Some(id) && str_of(at(Some(c), "kind")) == Some("feishu")) ||
      platform == Some("feishu") ||
      platform == Some("lark")
    feishu && w.ask("hub.chatHas", [js(id), js("begin")]) is Bool(true)
  }
  let own = str_of(at(Some(session), "connect")).unwrap_or("")
  if usable(own) {
    return own
  }
  let threads = arr_of(at(Some(w.with_threads_j(t => t.recent_session_threads(Json::string(key), Json::null()))), "threads")).unwrap_or([])
  for t in threads {
    let c = str_of(at(Some(t), "connect")).unwrap_or("")
    if usable(c) {
      return c
    }
  }
  let workspaces = w.with_hub(h => h.workspaces()).map(js)
  let home = if workspaces.length() > 0 { workspaces[0] } else { J::Null }
  let ws = jopt(w.with_hub(h => h.ws_of_arg((if session is Null { js(key) } else { session }).to_json())))
  let bots = []
  for c in connects {
    if str_of(at(Some(c), "kind")) != Some("feishu") || !(at(Some(c), "enabled") is Some(Bool(true))) {
      continue
    }
    let cws = match at(Some(c), "workspace") {
      None | Some(Null) => home
      Some(x) => x
    }
    if !(home is Null) && !jeq(cws, ws) {
      continue
    }
    if !usable(str_of(at(Some(c), "id")).unwrap_or("")) {
      continue
    }
    bots.push(c)
  }
  let id_of = (c : J) => str_of(at(Some(c), "id")).unwrap_or("")
  if bots.length() == 1 {
    return id_of(bots[0])
  }
  if bots.length() == 0 {
    raise fail_("this station has no Feishu bot in this chat's workspace")
  }
  let bind = (c : J, name : String) => match str_of(at(at(Some(c), "bind"), name)) {
    Some(v) if v != "" => Some(v)
    _ => None
  }
  let of_session = (name : String) => str_of(at(Some(session), name))
  let one = (picked : Array[J]) => if picked.length() == 1 { Some(id_of(picked[0])) } else { None }
  let found = match one(bots.filter(c => bind(c, "profile") is Some(p) && of_session("profile") == Some(p))) {
    Some(f) => Some(f)
    None =>
      match one(bots.filter(c => bind(c, "runtime") == of_session("runtime") && bind(c, "model") is Some(m) && of_session("model") == Some(m))) {
        Some(f) => Some(f)
        None => one(bots.filter(c => bind(c, "runtime") == of_session("runtime")))
      }
  }
  match found {
    Some(f) => f
    None => raise fail_("this chat has no Feishu bot of its own, and this workspace has several Feishu bots (\{bots.map(id_of).join(", ")})")
  }
}

///|
/// slack_api: a Slack Web API call from session `key`, as the bot of `via` (else `slack_connect_of`).
pub async fn slack_api(
  w : World,
  key : String,
  method : String,
  params : J,
  via : String?,
  bot : String?,
  save_files : Bool,
) -> String {
  let identity = message_identity(w, key)
  if !@session_hub.is_slack_method(method) {
    raise fail_("not a Slack method: \{quoted(method)}")
  }
  if starts(method, "admin.") || starts(method, "apps.") || starts(method, "oauth.") || method == "auth.revoke" {
    raise fail_("\{method} is not for agents: it manages the Slack app itself")
  }
  let connect = match via {
    Some(v) => v
    None => slack_connect_of(w, key, bot)
  }
  let text_of = (name : String) => str_of(at(Some(params), name))
  let channel = match text_of("channel") {
    Some(c) => Some(c)
    None => text_of("channel_id")
  }
  let surface = w.with_hub(h => h.surface(connect))
  let write = @mcp_tools.is_slack_write(method)
  let named = text_of("thread_ts")
  let about = match text_of("ts") {
    Some(t) => Some(t)
    None => text_of("timestamp")
  }
  let mut thread_ts : String? = None
  if write && channel is Some(ch) {
    thread_ts = match named {
      Some(n) => Some(n)
      None =>
        match about {
          Some(a) =>
            match str_of(at(Some(w.with_threads_j(t => t.thread_of_message(Json::string(surface), Json::string(ch), Json::string(a)))), "threadTs")) {
              Some(t) => Some(t)
              None => Some(a)
            }
          None => None
        }
    }
    let known = match thread_ts {
      Some(t) => w.with_threads_j(th => th.thread_at(Json::string(surface), Json::string(ch), Json::string(t)))
      None => J::Null
    }
    if !nullish(Some(known)) {
      let members = arr_of(Some(w.store_thread_sessions(at(Some(known), "id").unwrap_or(Null)))).unwrap_or([])
      if members.iter().any(m => str_of(at(Some(m), "session")) != Some(key) && str_of(at(Some(m), "connect")) == Some(connect)) {
        raise fail_("\{ch}/\{thread_ts.unwrap_or("")} is another session's conversation: this session cannot write there")
      }
    }
  }
  let posted_text = text_of("text").unwrap_or("")
  let result = call_api(w, connect, method, params)
  if write && channel is Some(ch) {
    let result_ts = str_of(at(Some(result), "ts"))
    let root = match thread_ts {
      Some(t) => Some(t)
      None => result_ts
    }
    if root is Some(r) {
      let thread = w.with_threads_j(t => t.open_thread(Json::string(surface), Json::string(ch), Json::string(r), Json::null(), Json::string(key)))
      let tid = at(Some(thread), "id").unwrap_or(Null)
      if w.with_threads_j(t => t.join_thread(tid.to_json(), Json::string(key), Json::string(connect))) is Bool(true) {
        w.log(
          "info",
          "hub",
          "session took part in a thread through slack_api",
          jo([("session", js(key)), ("channel", js(ch)), ("threadTs", js(r)), ("method", js(method))]),
        )
      }
      if result_ts is Some(rt) && method == "chat.postMessage" {
        let fields = [
          ("thread", tid),
          ("ts", js(rt)),
          ("authorKind", js("agent")),
          ("author", js(key)),
          ("text", js(posted_text)),
        ]
        if identity is Some(i) {
          fields.push(("agentIdentity", i))
        }
        let n = at_i(Some(w.store_insert_message(jo(fields))), 0).unwrap_or(Null)
        w.hub_shared(tid, n, key, posted_text)
      }
    }
  }
  let saved = if save_files {
    let answer_files = w.ask_u("chat.answerFiles", [js(connect), result])
    w.ask("hub.fetchedFor", [js(connect), js(key), js(""), match answer_files { Some(f) => f; None => jo([("$u", ji(1))]) }])
  } else {
    J::Null
  }
  let text = if saved is Null {
    stringify(result)
  } else {
    let kept = arr_of(at(Some(saved), "attachments"))
      .unwrap_or([])
      .map(a => jo([("name", at(Some(a), "name").unwrap_or(Null)), ("path", at(Some(a), "path").unwrap_or(Null)), ("size", at(Some(a), "size").unwrap_or(Null))]))
    stringify(spread(jo([("saved_files", ja(kept)), ("not_saved", at(Some(saved), "text").unwrap_or(Null))]), result))
  }
  let cs = chars(text)
  if cs.length() > 60000 {
    "\{cs[0:60000].to_array().join("")}… (cut at 60000 characters; ask for less, e.g. a smaller limit)"
  } else {
    text
  }
}
