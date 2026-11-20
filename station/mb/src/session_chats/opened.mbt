// Chats an agent opens for another (station/src/sessions/opened.ts, chat_create): a new session in a still.fail chat
// of its own, on this station or on another of the workspace. The chat begins with the opener's message, headed as its
// opening; it is opened for the opener's person (`person`) or led by its opener (`me`), who is told each time one of
// its turns ends. How a session is made is sessions/lifecycle.ts's (`dep.newSession`), which model it runs
// sessions/model-choice.ts's (`dep.candidates`, `dep.choose`, `dep.askWhich`), a context asked context-cap.ts's
// (`dep.contextAsked`); the workspace's presets are the hub's (`presets.list`, `presets.isHere`, `presets.nameOf`).

///|
pub let create_method : String = "session.create"

///|
pub let create_preset_method : String = "session.create.preset"

///|
pub let create_preset_tui_method : String = "session.create.preset.tui"

///|
pub let create_speed_method : String = "session.create.speed"

///|
pub let create_preset_speed_method : String = "session.create.preset.speed"

///|
pub let notice_method : String = "session.notice"

///|
/// A string argument, trimmed; None when left out or empty.
fn given_arg(args : J, name : String) -> String? {
  match at(Some(args), name) {
    None | Some(Null) => None
    Some(v) => {
      let t = trim(js_string(v))
      if t == "" {
        None
      } else {
        Some(t)
      }
    }
  }
}

///|
/// chat_create `for`: whether the opener leads the chat.
fn led_of(args : J) -> Bool raise Thrown {
  match given_arg(args, "for") {
    Some("me") => true
    Some("person") => false
    _ =>
      raise fail_(
        "for is required, \"me\" or \"person\": \"me\" for a chat you lead (a part of your work: it reports to you, what it asks is yours to decide or take to your person, and you check what it says before you tell anyone: skill stillfail-leading), \"person\" for a chat opened for your person (theirs from then on: you are told nothing of it)",
      )
  }
}

///|
fn key_of(args : J) -> String raise Thrown {
  guard given_arg(args, "key") is Some(key) else {
    raise fail_(
      "key is required: a name of your choosing for this chat (e.g. build-android); calling again with it gives the chat made then rather than another",
    )
  }
  if char_count(key) > 120 {
    raise fail_("key is too long (at most 120 characters)")
  }
  key
}

///|
async fn starter_of(w : World, key : String) -> J {
  let mut thread = J::Null
  try {
    thread = at(Some(w.dep("sessionThreadOf", [js(key)])), "thread").unwrap_or(Null)
  } catch {
    _ => ()
  }
  match at(Some(thread), "createdBy") {
    Some(c) if !(c is Null) => c
    _ =>
      match at(Some(w.store("getSession", [js(key)])), "createdBy") {
        Some(c) if !(c is Null) => c
        _ => js("local")
      }
  }
}

///|
async fn make_chat(w : World, o : J, more : J) -> J {
  let effort = at(Some(o), "effort").unwrap_or(Null)
  let bound = at(Some(o), "bound") is Some(Bool(true))
  let usual = if effort is Null && !bound {
    usual_effort(w, at(Some(o), "createdBy").unwrap_or(Null), at(Some(o), "runtime").unwrap_or(Null), at(Some(o), "model").unwrap_or(Null))
  } else {
    J::Null
  }
  let options = spread(
    more,
    jo([
      ("runtime", at(Some(o), "runtime").unwrap_or(Null)),
      ("model", at(Some(o), "model").unwrap_or(Null)),
      ("effort", if effort is Null { usual } else { effort }),
      ("title", at(Some(o), "title").unwrap_or(Null)),
      ("createdBy", at(Some(o), "createdBy").unwrap_or(Null)),
      ("ws", at(Some(o), "ws").unwrap_or(Null)),
    ]),
  )
  try {
    w.dep("newSession", [options])
  } catch {
    error => {
      if !(usual is Null) {
        try {
          return w.dep("newSession", [set_field(options, "effort", Null)])
        } catch {
          _ => ()
        }
      }
      let inherited = at(Some(o), "inherited") is Some(Bool(true))
      if !inherited || (at(Some(o), "model") is Some(Null) && effort is Null) {
        raise error
      }
      w.dep("newSession", [set_field(set_field(options, "model", Null), "effort", Null)])
    }
  }
}

///|
async fn preset_named(w : World, ws : J, named : String) -> J {
  let at_ws = if ws is Null {
    match at_i(Some(w.hub("workspaces", [])), 0) {
      Some(x) => x
      None => J::Null
    }
  } else {
    ws
  }
  let all = arr_of(Some(w.ask("presets.list", [at_ws]))).unwrap_or([])
  let low = lower(named)
  match all.search_by(p => str_of(at(Some(p), "id")) == Some(named)) {
    Some(i) => return all[i]
    None => ()
  }
  match all.search_by(p => lower(str_of(at(Some(p), "name")).unwrap_or("")) == low) {
    Some(i) => return all[i]
    None => ()
  }
  if all.length() == 0 {
    raise fail_("no preset \{named}: this station has none (people make them in the app). Leave preset out to open the chat with none")
  }
  raise fail_("no preset \{named} on this station; its presets: \{all.map(p => str_of(at(Some(p), "name")).unwrap_or("")).join(", ")}")
}

///|
fn preset_stations(p : J) -> Array[String] {
  let list = match str_of(at(Some(p), "station")) {
    Some(s) => [s]
    None => arr_of(at(Some(p), "stations")).unwrap_or([]).map(x => str_of(Some(x)).unwrap_or(""))
  }
  list.map(s => slice(s, last_index_of(s, "/") + 1))
}

///|
async fn bound_here(w : World, ws : J, pm : J, name : String) -> (J, J) {
  let model = str_of(at(Some(pm), "model")).unwrap_or("")
  let runtime = match str_of(at(Some(pm), "runtime")) {
    Some(r) => Some(r)
    None => {
      let cands = @session_hub.candidates(json_items(w.hub("profilesIn", [ws])), None).map(@jsjson.JValue::of_json)
      let mut found = None
      for c in cands {
        match str_of(at(Some(c), "model")) {
          Some(m) if same_model(w, m, model) => {
            found = str_of(at(Some(c), "runtime"))
            break
          }
          _ => ()
        }
      }
      found
    }
  }
  guard runtime is Some(runtime) && runtime_kinds.contains(runtime) else {
    raise fail_("the preset \{name} runs \{model}, which no account on the station it is opened on runs")
  }
  let choice = jo([
    ("runtime", js(runtime)),
    ("model", js(model)),
    ("effort", match at(Some(pm), "effort") { Some(e) => e; None => J::Null }),
    ("bound", jb(true)),
  ])
  let more = []
  if at(Some(pm), "tui") is Some(Bool(true)) { more.push(("tui", jb(true))) }
  match at(Some(pm), "speed") {
    Some(Str(_) as s) => more.push(("speed", s))
    _ => ()
  }
  more.push(("fast", match at(Some(pm), "fast") { Some(f) => f; None => J::Null }))
  more.push(("context", match at(Some(pm), "context") { Some(c) => c; None => J::Null }))
  more.push(("profile", match at(Some(pm), "profile") { Some(c) => c; None => J::Null }))
  more.push(("profiles", match at(Some(pm), "profiles") { Some(c) => c; None => J::Null }))
  (choice, jo(more))
}

///|
async fn copy_for(w : World, p : J, here : String, there : String) -> J {
  let dirs = []
  for d in arr_of(at(Some(p), "dirs")).unwrap_or([]) {
    let station = str_of(at(Some(d), "station"))
    let rest = without(d, ["station", "stationName", "guides", "skills"])
    match station {
      None => dirs.push(set_field(rest, "elsewhere", js(here)))
      Some(s) =>
        if w.ask("presets.isHere", [js(s)]) is Bool(true) {
          dirs.push(set_field(rest, "elsewhere", js(here)))
        } else if slice(s, last_index_of(s, "/") + 1) == there {
          dirs.push(rest)
        } else {
          dirs.push(set_field(rest, "elsewhere", w.ask("presets.nameOf", [js(s), jopt(str_of(at(Some(d), "stationName")))])))
        }
    }
  }
  let stations = match str_of(at(Some(p), "station")) {
    Some(s) => Some(J::Arr([js(s)]))
    None => at(Some(p), "stations")
  }
  let fields = [
    ("id", at(Some(p), "id").unwrap_or(Null)),
    ("name", at(Some(p), "name").unwrap_or(Null)),
    ("dirs", ja(dirs)),
    ("instructions", at(Some(p), "instructions").unwrap_or(Null)),
  ]
  match at(Some(p), "model") {
    Some(Obj(_) as m) => fields.push(("model", m))
    _ => ()
  }
  match stations {
    Some(Arr(xs) as ss) if xs.length() > 0 => fields.push(("stations", ss))
    _ => ()
  }
  jo(fields)
}

///|
async fn used_within(w : World) -> Double {
  w.now() - @session_hub.used_within_ms
}

///|
async fn usual_effort(w : World, created_by : J, runtime : J, model : J) -> J {
  let used = w.store("effortsUsedBy", [created_by, runtime, model, jn(used_within(w))])
  match at(at_i(Some(used), 0), "effort") {
    Some(e) => e
    None => Null
  }
}

///|
async fn chosen_here(w : World, created_by : J, ws : J, runtime : J) -> J {
  let rt = str_of(Some(runtime))
  let cands = @session_hub.candidates(json_items(w.hub("profilesIn", [ws])), rt)
  if cands.length() == 0 {
    raise fail_(
      match rt {
        Some(r) => "no \{r} profile on the station it is opened on"
        None => "no profile on the station it is opened on"
      },
    )
  }
  let used = json_items(w.store("modelsUsedBy", [created_by, jn(used_within(w))]))
  let leads = @session_hub.candidates(json_items(w.hub("profilesIn", [ws])), rt, leads=true)
  let c = @jsjson.JValue::of_json(@session_hub.choose(cands, used, leads~))
  match at(Some(c), "ask") {
    Some(ask) => raise fail_(@session_hub.ask_which(json_items(ask), "the station it is opened on"))
    None => ()
  }
  let pick = at(Some(c), "pick")
  jo([("runtime", at(pick, "runtime").unwrap_or(Null)), ("model", at(pick, "model").unwrap_or(Null))])
}

///|
fn address_of_thread(thread : J) -> String {
  address_of_row(at(Some(thread), "thread"))
}

///|
async fn station_named(w : World, key : String, named : String?) -> String? {
  guard named is Some(named) else { return None }
  let link = str_of(Some(w.hub("link", [js(key)])))
  let here = match link {
    Some(l) => @session_storage.linked_station(l)
    None => None
  }
  if Some(named) == here {
    return None
  }
  let call = w.dep("peersOf", [js(key)])
  if call is Null {
    raise fail_("other stations cannot be reached from this one yet: leave station out to open the chat here")
  }
  let roster = w.call_fn(call, [js(""), jo([("method", js("peers"))])])
  let stations = arr_of(at(Some(roster), "stations")).unwrap_or([])
  let low = lower(named)
  let found = match stations.search_by(s => str_of(at(Some(s), "id")) == Some(named)) {
    Some(i) => Some(stations[i])
    None =>
      match stations.search_by(s => match str_of(at(Some(s), "name")) { Some(n) => lower(n) == low; None => false }) {
        Some(i) => Some(stations[i])
        None => None
      }
  }
  match found {
    Some(f) if str_of(at(Some(f), "id")) is Some(id) => if Some(id) == here { None } else { Some(id) }
    _ => {
      let names = stations.filter_map(s => match str_of(at(Some(s), "name")) {
        Some(n) if n != "" => Some(n)
        _ => str_of(at(Some(s), "id"))
      })
      raise fail_(
        "no station \{named} in this workspace\{if names.length() > 0 { "; its stations: " + names.join(", ") } else { "" }}",
      )
    }
  }
}

///|
fn opened_said(session : String, link : String?, thread : String, station : String?, again : Bool, led : Bool) -> String {
  let where_ = match station {
    None => "this station"
    Some(s) => "station \{s}"
  }
  let shown = match link {
    Some(l) => l
    None => session
  }
  let first = if again {
    "This key already opened \{shown} (\{thread} on \{where_}); nothing new was opened or sent."
  } else {
    "Opened \{shown} (\{thread} on \{where_}); its agent is \{session}."
  }
  if !led {
    return "\{first} It is your person's chat now: they work with it there, what it asks goes to them and you are told nothing of it. Say where it is in your chat and do not take up or pass on its work."
  }
  "\{first} You lead it: put it in your goal ledger (the direction it is of, what counts as done, the evidence it is to bring: skill stillfail-leading). Each time a turn there ends all_done or need_human (or fails), you are told here: wait for it by ending your turn waiting. What it asks is yours to decide, or to take to your person yourself. Write to its agent with session_send to its link; read it with chat_read."
}

///|
async fn say_opened(w : World, key : String, title : String, link : String?, led : Bool) -> Unit {
  let latest = w.store("latestThread", [js(key)])
  if nullish(Some(latest)) {
    return
  }
  let row = at(Some(latest), "thread")
  let text = w.tr(
    if led { "station.session.opened" } else { "station.session.openedForPerson" },
    args=[("chat", chat_named(str_of(at(row, "surface")).unwrap_or(""), title, link))],
  )
  try {
    let ts = w.chat(str_of(at(Some(latest), "connect")).unwrap_or(""), "post", [thread_ref(row), js(mark_notice(text)), ja([])])
    w.store("insertMessage", [message_j(at(row, "id").unwrap_or(Null), ts, station_author, station_author, text, Some(ja([])))]) |> ignore
  } catch {
    e =>
      w.log("warn", "hub", "an opened chat was not said in its opener's", jo([("session", js(key)), ("error", js(thrown_message(e)))]))
  }
}

///|
async fn opener_said(w : World, thread : J, author : String, agent_only : Bool) -> Bool {
  if w.has("openedChatSaid") {
    return w.hub("openedChatSaid", [thread, js(author), jb(agent_only)]) is Bool(true)
  }
  arr_of(Some(w.store("messagesBefore", [thread, Null, ji(200)])))
  .unwrap_or([])
  .iter()
  .any(m => str_of(at(Some(m), "author")) == Some(author) &&
    (!agent_only || str_of(at(Some(m), "authorKind")) == Some("agent")))
}

///|
/// The first line of `text`, cut to 60 units (`text.split("\n")[0].slice(0, 60)`).
fn first_line60(text : String) -> String {
  slice(split(text, "\n")[0], 0, b=60)
}

///|
/// chat_create from session `key`. (One asked again with a key while it is made waits for it: the station's own
/// queue, `oneByKey`, keeps calls of one key in turn.)
pub async fn chat_create(w : World, key : String, args : J) -> String {
  let row = w.store("getSession", [js(key)])
  if row is Null {
    raise fail_("unknown session")
  }
  let opened_by = w.store("openerOf", [js(key)])
  if !(opened_by is Null) && !(at(Some(opened_by), "led") is Some(Bool(false))) {
    raise fail_(
      "this chat was opened by another agent, and opens none itself: ask its opener (session_send) or a person to open more",
    )
  }
  let k = key_of(args)
  let led = led_of(args)
  guard given_arg(args, "text") is Some(text) else {
    raise fail_("text is required: the first message, what the new chat's agent is to do, standing on its own")
  }
  if char_count(text) > max_text {
    raise fail_("text is too long (at most \{max_text} characters): put the rest in a file and attach it")
  }
  let runtime = given_arg(args, "runtime")
  if runtime is Some(r) && !runtime_kinds.contains(r) {
    raise fail_("runtime must be one of \{runtime_kinds.join(", ")}")
  }
  let model = given_arg(args, "model")
  let effort = given_arg(args, "effort")
  match at(Some(args), "fast") {
    None | Some(Null) | Some(Bool(_)) => ()
    _ => raise fail_("fast must be true or false")
  }
  let fast = match at(Some(args), "fast") {
    Some(Bool(b)) => Some(b)
    _ => None
  }
  let speed = model_speed(at(Some(args), "speed"))
  if !nullish(at(Some(args), "speed")) && speed is None {
    raise fail_("speed must be standard, fast or ultrafast")
  }
  let context = match hub_ok(() => @session_hub.context_asked(w.words.to_hub(w.lang.val), opt_json(at(Some(args), "context")), w.lang.val)) {
    Some(Some(n)) => jn(n)
    _ => J::Null
  }
  let preset_name = given_arg(args, "preset")
  let ws = match at(Some(row), "ws") {
    Some(x) => x
    None => J::Null
  }
  let preset = match preset_name {
    None => J::Null
    Some(n) => preset_named(w, ws, n)
  }
  if at(Some(preset), "model") is Some(Obj(_) as pm) &&
    (runtime is Some(_) || model is Some(_) || effort is Some(_) || fast is Some(_) || speed is Some(_) || !(context is Null)) {
    raise fail_(
      "the preset \{str_of(at(Some(preset), "name")).unwrap_or("")} runs \{str_of(at(Some(pm), "model")).unwrap_or("")} as it says (its runtime, effort, Fast and context too): leave runtime, model, effort, fast, speed and context out, or leave preset out to choose them yourself",
    )
  }
  let binds_to = if preset is Null { [] } else { preset_stations(preset) }
  let choice = jo([
    ("runtime", match runtime { Some(r) => js(r); None => at(Some(row), "runtime").unwrap_or(Null) }),
    ("model", jopt(model)),
    ("effort", jopt(effort)),
    ("inherited", jb(false)),
  ])
  let title = given_arg(args, "title")
  if title is Some(t) && char_count(t) > 120 {
    raise fail_("title is too long (at most 120 characters)")
  }
  let paths = match at(Some(args), "files") {
    Some(Arr(xs)) => xs.map(js_string)
    _ => []
  }
  let files = arr_of(Some(w.dep("sendable", [js(key), jsa(paths)]))).unwrap_or([])
  let station_arg = match given_arg(args, "station") {
    Some(s) => Some(s)
    None => if binds_to.length() == 1 { Some(binds_to[0]) } else { None }
  }
  let there = station_named(w, key, station_arg)
  let target_station = match there {
    Some(t) => Some(t)
    None => str_of(Some(w.hub("station", [])))
  }
  if !(preset is Null) && binds_to.length() > 0 && target_station is Some(t) && !binds_to.contains(t) {
    raise fail_(
      "the preset \{str_of(at(Some(preset), "name")).unwrap_or("")} opens its chats only on station\{if binds_to.length() > 1 { "s" } else { "" }} \{binds_to.join(", ")}: name one of them as station",
    )
  }
  let created_by = starter_of(w, key)
  let (from, from_link) = sender(w, key)
  let send_here = async fn(child : String, thread : J) {
    let tid = at(at(Some(thread), "thread"), "id").unwrap_or(Null)
    if opener_said(w, tid, key, true) {
      return
    }
    let kept = if files.length() > 0 {
      attach(w, key, files.map(f => str_of(at(Some(f), "path")).unwrap_or("")), child)
    } else {
      J::Arr([])
    }
    post_from(w, thread, key, from, from_link, text, [child], kept, true) |> ignore
  }
  let before = w.store("openedWith", [js(""), js(key), js(k), js(there.unwrap_or(""))])
  if !(before is Null) {
    let child = str_of(at(Some(before), "child")).unwrap_or("")
    let mut thread = child
    if there is None && !(w.store("getSession", [js(child)]) is Null) {
      let chat = w.dep("sessionThreadOf", [js(child)])
      send_here(child, chat)
      thread = address_of_thread(chat)
    }
    return opened_said(child, str_of(at(Some(before), "link")), thread, there, true, !(at(Some(before), "led") is Some(Bool(false))))
  }
  match there {
    None => {
      let bound = match at(Some(preset), "model") {
        Some(Obj(_) as pm) => Some(bound_here(w, ws, pm, str_of(at(Some(preset), "name")).unwrap_or("")))
        _ => None
      }
      let chosen = match bound {
        Some((c, _)) => c
        None =>
          if model is None {
            chosen_here(w, created_by, ws, jopt(runtime))
          } else {
            choice
          }
      }
      let more_fields = []
      if !(preset is Null) {
        more_fields.push(("preset", at(Some(preset), "id").unwrap_or(Null)))
      }
      more_fields.push(("fast", match fast { Some(b) => jb(b); None => J::Null }))
      if speed is Some(s) {
        more_fields.push(("speed", js(s)))
      }
      more_fields.push(("context", context))
      let mut more = jo(more_fields)
      if bound is Some((_, bm)) {
        more = spread(more, bm)
      }
      let made = make_chat(
        w,
        spread(spread(spread(choice, chosen), jo([("title", jopt(title)), ("createdBy", created_by), ("ws", ws)])), J::Obj([])),
        more,
      )
      let child = str_of(at_i(Some(made), 0)).unwrap_or("")
      let chat = at_i(Some(made), 1).unwrap_or(Null)
      let link = str_of(Some(w.hub("link", [js(child)])))
      w.store("insertOpened", [
        jo([
          ("childStation", js("")),
          ("child", js(child)),
          ("parentStation", js("")),
          ("parent", js(key)),
          ("key", js(k)),
          ("title", jopt(title)),
          ("link", jopt(link)),
          ("openerTitle", js(from)),
          ("led", jb(led)),
        ]),
      ])
      |> ignore
      let thread = jo([("thread", chat), ("connect", js(internal_connect))])
      send_here(child, thread)
      say_opened(w, key, match title { Some(t) => t; None => first_line60(text) }, link, led)
      opened_said(child, link, address_of_thread(thread), None, false, led)
    }
    Some(there) => {
      let call = w.dep("peersOf", [js(key)])
      let preset_speed = match at(at(Some(preset), "model"), "speed") {
        Some(Str(_)) => true
        _ => false
      }
      let method = if at(at(Some(preset), "model"), "tui") is Some(Bool(true)) {
        create_preset_tui_method
      } else if !(preset is Null) {
        if speed is Some(_) || preset_speed { create_preset_speed_method } else { create_preset_method }
      } else if speed is Some(_) {
        create_speed_method
      } else {
        create_method
      }
      let fields = [
        ("method", js(method)),
        ("session", js(key)),
        ("key", js(k)),
        ("title", jopt(title)),
        ("runtime", at(Some(choice), "runtime").unwrap_or(Null)),
        ("model", jopt(model)),
        ("effort", jopt(effort)),
        ("inherited", jb(false)),
        ("choose", jb(model is None)),
        ("runtimeGiven", jb(runtime is Some(_))),
        ("createdBy", created_by),
        ("from", jo([("title", js(from)), ("link", jopt(from_link))])),
        ("led", jb(led)),
      ]
      if fast is Some(b) {
        fields.push(("fast", jb(b)))
      }
      if speed is Some(s) {
        fields.push(("speed", js(s)))
      }
      if !(context is Null) {
        fields.push(("context", context))
      }
      if !(preset is Null) {
        fields.push(("presetCopy", copy_for(w, preset, str_of(Some(w.hub("station", []))).unwrap_or(""), there)))
      }
      let request = jo(fields)
      let made = try {
        w.call_fn(call, [js(there), request])
      } catch {
        e => {
          let why = thrown_message(e)
          if thrown_kind(e) == "Refused" && @session_storage.from_before(why) {
            raise fail_(
              "station \{there} is not updated yet: chats cannot be opened there\{if !(preset is Null) { " with a preset" } else { "" }}\{if speed is Some(_) || preset_speed { " at the requested speed" } else { "" }}",
            )
          }
          raise fail_(
            "not opened on station \{there}: \{why}. If it timed out it may have been opened: call chat_create again with the same key, which gives that chat rather than another",
          )
        }
      }
      let child = str_of(at(Some(made), "session")).unwrap_or("")
      if child == "" {
        raise fail_("station \{there} answered without the chat it opened")
      }
      let link = str_of(at(Some(made), "link"))
      let thread = str_of(at(Some(made), "thread")).unwrap_or(child)
      if !(at(Some(made), "said") is Some(Bool(true))) {
        try {
          let mut message = jo([
            ("method", js("session.message")),
            ("session", js(key)),
            ("to", js(child)),
            ("text", js(text)),
            ("from", jo([("title", js(from)), ("link", jopt(from_link))])),
            ("opened", jb(true)),
          ])
          if files.length() > 0 {
            message = set_field(message, "files", w.dep("sendAlong", [call, js(there), js(key), js(child), ja(files)]))
          }
          w.call_fn(call, [js(there), message]) |> ignore
        } catch {
          e =>
            raise fail_(
              "opened \{match link { Some(l) => l; None => child }} on station \{there}, but its first message was not sent: \{thrown_message(e)}. Call chat_create again with the same key: it sends it once, if it has not arrived",
            )
        }
      }
      w.store("insertOpened", [
        jo([
          ("childStation", js(there)),
          ("child", js(child)),
          ("parentStation", js("")),
          ("parent", js(key)),
          ("key", js(k)),
          ("title", jopt(title)),
          ("link", jopt(link)),
          ("led", jb(led)),
        ]),
      ])
      |> ignore
      say_opened(w, key, match title { Some(t) => t; None => first_line60(text) }, link, led)
      opened_said(child, link, thread, Some(there), false, led)
    }
  }
}

///|
/// A chat another station's session opens here (chat_create there, from station `peer`), in workspace `ws`.
pub async fn create_for_peer(w : World, peer : String, request : J, ws : J) -> J {
  let parent = str_of(at(Some(request), "session")).unwrap_or("")
  if parent == "" {
    raise fail_("session is required")
  }
  let k = key_of(request)
  let before = w.store("openedWith", [js(peer), js(parent), js(k), js("")])
  let answer = async fn(child : String) {
    let thread = w.dep("sessionThreadOf", [js(child)])
    let said = opener_said(w, at(at(Some(thread), "thread"), "id").unwrap_or(Null), "\{peer}/\{parent}", false)
    jo([
      ("session", js(child)),
      ("link", jopt(str_of(Some(w.hub("link", [js(child)]))))),
      ("thread", js(address_of_thread(thread))),
      ("said", jb(said)),
    ])
  }
  if !(before is Null) {
    let child = str_of(at(Some(before), "child")).unwrap_or("")
    if !(w.store("getSession", [js(child)]) is Null) && (ws is Null || w.hub("inWorkspace", [js(child), ws]) is Bool(true)) {
      return answer(child)
    }
    raise fail_("the chat key \{k} opened here is gone (deleted, or of another workspace): use another key")
  }
  let runtime = str_of(at(Some(request), "runtime")).unwrap_or("")
  if !runtime_kinds.contains(runtime) {
    raise fail_("runtime must be one of \{runtime_kinds.join(", ")}")
  }
  let title = given_arg(request, "title")
  let created_by = match given_arg(request, "createdBy") {
    Some(c) => c
    None => "\{peer}/\{parent}"
  }
  let model = given_arg(request, "model")
  let method = str_of(at(Some(request), "method"))
  let copy = if method == Some(create_preset_method) || method == Some(create_preset_speed_method) || method == Some(create_preset_tui_method) {
    Some(preset_copy_input(at(Some(request), "presetCopy").unwrap_or(Null)))
  } else {
    None
  }
  let bound = match copy {
    Some(c) =>
      match at(Some(c), "model") {
        Some(Obj(_) as pm) => Some(bound_here(w, ws, pm, str_of(at(Some(c), "name")).unwrap_or("")))
        _ => None
      }
    None => None
  }
  let chosen = match bound {
    Some((c, _)) => c
    None =>
      if at(Some(request), "choose") is Some(Bool(true)) && model is None {
        chosen_here(w, js(created_by), ws, if at(Some(request), "runtimeGiven") is Some(Bool(true)) { js(runtime) } else { J::Null })
      } else {
        jo([("runtime", js(runtime)), ("model", jopt(model))])
      }
  }
  let mut more = jo([
    ("fast", match at(Some(request), "fast") { Some(Bool(b)) => jb(b); _ => J::Null }),
    ("speed", jopt(model_speed(at(Some(request), "speed")))),
    (
      "context",
      match hub_ok(() => @session_hub.context_asked(w.words.to_hub(w.lang.val), opt_json(at(Some(request), "context")), w.lang.val)) {
        Some(Some(n)) => jn(n)
        _ => J::Null
      },
    ),
  ])
  if copy is Some(c) {
    more = set_field(more, "presetCopy", c)
  }
  if bound is Some((_, bm)) {
    more = spread(more, bm)
  }
  let o = spread(
    spread(jo([("effort", jopt(given_arg(request, "effort")))]), chosen),
    jo([("inherited", jb(at(Some(request), "inherited") is Some(Bool(true)))), ("title", jopt(title)), ("createdBy", js(created_by)), ("ws", ws)]),
  )
  let made = make_chat(w, o, more)
  let child = str_of(at_i(Some(made), 0)).unwrap_or("")
  let opener_title = match str_of(at(at(Some(request), "from"), "title")) {
    Some(t) if t != "" => js(t)
    _ => J::Null
  }
  let led = match at(Some(request), "led") {
    Some(Bool(false)) => jb(false)
    Some(Bool(true)) => jb(true)
    _ => J::Null
  }
  w.store("insertOpened", [
    jo([
      ("childStation", js("")),
      ("child", js(child)),
      ("parentStation", js(peer)),
      ("parent", js(parent)),
      ("key", js(k)),
      ("title", jopt(title)),
      ("link", jopt(str_of(Some(w.hub("link", [js(child)]))))),
      ("openerTitle", opener_title),
      ("led", led),
    ]),
  ])
  |> ignore
  w.log("info", "hub", "chat opened for another station's session", jo([("session", js(child)), ("station", js(peer)), ("opener", js(parent))]))
  answer(child)
}

///|
/// What an opener is told of a turn of a chat it opened.
pub fn opened_notice(title : String, link : String?, state : String, words : String?, led : Bool?) -> String {
  let chat = match link {
    Some(l) => "\"\{title}\" (\{l})"
    None => "\"\{title}\""
  }
  let said = match words {
    Some(w) if w != "" => ": \{w}"
    _ => ""
  }
  if led == Some(true) {
    let ended = match state {
      "need_human" =>
        "asks you\{said}. It is yours to decide (session_send it your answer), or to take to your person in your own chat, with what you checked; no person was asked"
      "failed" => "stopped with an error\{said}"
      "stopped" => "was stopped by a person"
      _ => "ended its turn all_done\{said}"
    }
    return "The chat you lead, \{chat}, \{ended}. Its words are its claims: check against your goal ledger before you tell anyone, yourself in the code or data any it gives up, finds no gain in or says needs your person, and anything against your person's rules (skill stillfail-leading). Read it with chat_read; write to its agent with session_send to its link."
  }
  let ended = match state {
    "need_human" => "needs a person\{said}. They are asked there; help if you can, or wait"
    "failed" => "stopped with an error\{said}"
    "stopped" => "was stopped by a person"
    _ => "ended its turn all_done\{said}"
  }
  "The chat you opened, \{chat}, \{ended}. Read it with chat_read; write to its agent with session_send to its link."
}

///|
/// A turn of session `key` ended: its opener, if an agent opened its chat, is told how. (A notice to another station
/// that fails is said in the chat: `settled_far_failed`.)
pub async fn settled(w : World, key : String, state : String, words : String?) -> Unit {
  let opener = w.store("openerOf", [js(key)])
  if opener is Null {
    return
  }
  if at(Some(opener), "led") is Some(Bool(false)) {
    return
  }
  let (title, link) = sender(w, key)
  let parent_station = str_of(at(Some(opener), "parentStation")).unwrap_or("")
  let led = match at(Some(opener), "led") {
    Some(Bool(b)) => Some(b)
    _ => None
  }
  if parent_station == "" {
    w.store("setOpenedState", [js(""), js(key), js(state)]) |> ignore
    try {
      w.hub("notify", [at(Some(opener), "parent").unwrap_or(Null), js(opened_notice(title, link, state, words, led))]) |> ignore
    } catch {
      e =>
        w.log(
          "warn",
          "hub",
          "the opener of a chat was not told",
          jo([("session", js(key)), ("opener", at(Some(opener), "parent").unwrap_or(Null)), ("error", js(thrown_message(e)))]),
        )
    }
    return
  }
  let call = w.dep("peersOf", [js(key)])
  try {
    if call is Null {
      raise fail_("other stations cannot be reached from this one yet")
    }
    w.call_fn(call, [
      js(parent_station),
      jo([
        ("method", js(notice_method)),
        ("session", js(key)),
        ("to", at(Some(opener), "parent").unwrap_or(Null)),
        ("state", js(state)),
        ("words", jopt(words)),
        ("title", js(title)),
      ]),
    ])
    |> ignore
  } catch {
    e => {
      w.log(
        "warn",
        "hub",
        "the opener of a chat on another station was not told",
        jo([("session", js(key)), ("station", js(parent_station)), ("error", js(thrown_message(e)))]),
      )
      let latest = w.store("latestThread", [js(key)])
      if nullish(Some(latest)) {
        return
      }
      let row = at(Some(latest), "thread")
      let text = w.tr("station.session.openerNotTold", args=[("error", thrown_message(e))])
      try {
        let ts = w.chat(str_of(at(Some(latest), "connect")).unwrap_or(""), "post", [thread_ref(row), js(mark_notice(text)), ja([])])
        w.store("insertMessage", [message_j(at(row, "id").unwrap_or(Null), ts, station_author, station_author, text, Some(ja([])))]) |> ignore
      } catch {
        _ => ()
      }
    }
  }
}

///|
/// How a turn of a chat this station's session opened on station `peer` ended, told in workspace `ws`.
pub async fn notice_for_peer(w : World, peer : String, request : J, ws : J) -> J {
  let child = str_of(at(Some(request), "session")).unwrap_or("")
  let parent = str_of(at(Some(request), "to")).unwrap_or("")
  if !(ws is Null) && !(w.hub("inWorkspace", [js(parent), ws]) is Bool(true)) {
    raise fail_("\{parent} opened no chat \{child} on that station")
  }
  let state = str_of(at(Some(request), "state"))
  guard state is Some(("all_done" | "need_human" | "failed" | "stopped") as state) else {
    raise fail_("state must be all_done, need_human, failed or stopped")
  }
  let records = arr_of(Some(w.store("openedBy", [js(parent)]))).unwrap_or([])
  guard records.search_by(o => str_of(at(Some(o), "childStation")) == Some(peer) && str_of(at(Some(o), "child")) == Some(child)) is Some(i) else {
    raise fail_("\{parent} opened no chat \{child} on that station")
  }
  let record = records[i]
  w.store("setOpenedState", [js(peer), js(child), js(state)]) |> ignore
  let title = match given_arg(request, "title") {
    Some(t) => t
    None =>
      match str_of(at(Some(record), "title")) {
        Some(t) => t
        None => child
      }
  }
  let led = match at(Some(record), "led") {
    Some(Bool(b)) => Some(b)
    _ => None
  }
  w.hub("notify", [js(parent), js(opened_notice(title, str_of(at(Some(record), "link")), state, given_arg(request, "words"), led))])
  |> ignore
  jo([("told", jb(true))])
}
