// instructions.ts: what the agent is told about its situation (appended to the runtime's own system prompt), what it
// is told when the station picks a session up again, and how messages and a thread's history are put to it. A message,
// a card's choice and a widget's state are the store's rows as JSON (rows.ts `MessageRow`, `PendingMessage`,
// `CardChoice`, `WidgetModel`).

///|
/// `SITE_INSTRUCTIONS_MAX`.
pub let site_instructions_max : Int = 4096

///|
/// `MEMORY_MOST`, `SKILL_MOST`, `LINE_MOST`.
pub let memory_most : Int = 8 * 1024

///|
pub let skill_most : Int = 24 * 1024

///|
pub let line_most : Int = 1500

///|
/// rows.ts `STILLFAIL_SURFACE` and `STATION_AUTHOR`.
let stillfail_surface : String = "chat"

///|
let station_author : String = "station"

///|
fn instructions(project : String, workspace : String, repos_dir : String, memory_path : String, station : String) -> String {
  let out = StringBuilder::new()
  for i, piece in instructions_pieces {
    out.write_string(piece)
    if i < instructions_places.length() {
      out.write_string(
        match instructions_places[i] {
          "P" => project
          "W" => workspace
          "R" => repos_dir
          "M" => memory_path
          "A" => if station == "" { "" } else { " You are on station \{station}." }
          _ => if station == "" { "Studio" } else { station }
        },
      )
    }
  }
  out.to_string()
}

///|
/// `MOVE_LINE`: what points an agent at moving a station's things, said only where moving is on.
let move_line : String = " To move chats, or a whole station, to another station, skill stillfail-move."

///|
/// `sessionInstructions`: `project` the directory of a session begun in a terminal and continued here; `memory` the
/// workspace's memory as it is now; `site` what the deployment adds; `station` this station's name ("" where none);
/// `move` whether moving to another station is on here (its skill named only then).
pub fn session_instructions(
  workspace : String,
  project : String?,
  repos_dir : String,
  memory_path : String,
  memory : String,
  site? : String = "",
  station? : String = "",
  move? : Bool = true,
) -> String {
  let project_line = match project {
    None => ""
    Some(p) =>
      "- Project directory: \{p}. This session began outside still.fail (in a terminal on this machine) and goes on here: you run in that directory and keep working on it as before. The session workspace below is for scratch files only.\n"
  }
  let told = instructions(project_line, workspace, repos_dir, memory_path, station)
  (if move { told } else { replace_first(told, move_line, "") }) +
  (if site == "" { "" } else { "\n\n\{site}" }) +
  (if memory == "" { "" } else { "\n\n<memory path=\"\{memory_path}\">\n\{memory}\n</memory>" })
}

///|
/// `readSiteInstructions` once its file is read (`text`: none where it did not read): trimmed, cut at
/// SITE_INSTRUCTIONS_MAX units.
pub fn site_instructions_of(text : String?) -> String {
  let trimmed = trim(text.unwrap_or(""))
  if trimmed.length() > site_instructions_max {
    sub(trimmed, 0, to=site_instructions_max)
  } else {
    trimmed
  }
}

///|
/// `readSiteInstructions`: what the deployment adds (`STILLFAIL_SITE_INSTRUCTIONS`, a file), read off the station's
/// thread by the shell.
pub async fn read_site_instructions(host : @host.Host, path : String?) -> String {
  match path {
    None | Some("") => ""
    Some(p) => site_instructions_of(read_text(host, p))
  }
}

///|
/// `readMemory`: the workspace's memory at `path` as it is now, with what of it has grown past what an agent can use
/// (`overgrown`) said after it.
pub async fn read_memory(host : @host.Host, path : String) -> String {
  let memory = trim(read_text(host, path).unwrap_or(""))
  let files = [("MEMORY.md", memory)]
  for s in skills_beside(host, path) {
    files.push(s)
  }
  let grown = overgrown(files)
  if grown == "" {
    memory
  } else {
    "\{memory}\n\n\{grown}"
  }
}

///|
/// `skillsBeside`: the team skills' SKILL.md beside the memory at `path`, as [relative path, text], sorted.
async fn skills_beside(host : @host.Host, path : String) -> Array[(String, String)] {
  let dir = join([dirname(path), "skills"])
  let out = []
  for e in read_dir(host, dir) {
    if e.1 != "dir" {
      continue
    }
    if read_text(host, join([dir, e.0, "SKILL.md"])) is Some(text) {
      out.push(("skills/\{e.0}/SKILL.md", text))
    }
  }
  sort_js(out, f => f.0)
}

///|
/// `overgrown`: what of `files` ([relative path, text]) is past MEMORY_MOST, SKILL_MOST or LINE_MOST, as a note to the
/// agent; "" when nothing is.
pub fn overgrown(files : Array[(String, String)]) -> String {
  let kb = (n : Int) => "\{(n + 1023) / 1024} KB"
  let said = []
  for f in files {
    let (rel, text) = f
    let bytes = utf8_length(text)
    let most = if rel == "MEMORY.md" { memory_most } else { skill_most }
    let mut long = 0
    for line in text.split("\n") {
      if utf8_length(line.to_owned()) > line_most {
        long += 1
      }
    }
    let why = []
    if bytes > most {
      why.push("\{kb(bytes)}, past \{kb(most)}")
    }
    if long > 0 {
      why.push("\{long} line\{if long == 1 { "" } else { "s" }} past \{line_most} bytes")
    }
    if why.length() > 0 {
      said.push("- \{rel}: \{why.join("; ")}")
    }
  }
  if said.is_empty() {
    return ""
  }
  "[still.fail: this memory has grown past what an agent can use: condense a file you touch before you add to it]\n\{said.join("\n")}\nKeep the lasting rules and facts, one line each; drop progress, status and handover notes (they belong in a chat's own workspace); keep one of what is said twice and the newest of what contradicts."
}

///|
/// `nameUntitled`.
pub fn name_untitled(to : String) -> String {
  "The chat \{to} still has no title, and nobody is at work in it now. Give it one: chat_post with only to \"\{to}\" and title, a few words on what it is about in the language its people use. Post nothing else, then record again the state you just ended with (chat_state, with the same done or need)."
}

///|
fn chat_histories(threads : Array[String]) -> String {
  threads.join(", ")
}

///|
/// `resumeLost`.
pub fn resume_lost(key : String, threads : Array[String], terminal? : String? = None) -> String {
  let term = match terminal {
    None => ""
    Some(path) =>
      "this session began in a terminal, and what was said there is in \{path} (its runtime's own transcript: read it from its end); "
  }
  let more = if threads.is_empty() {
    ""
  } else {
    ", and chat_history for \{chat_histories(threads)}"
  }
  "Your earlier conversation could not be restored: this is a new one. Before you answer, read back what you need from where it is: \{term}session_history with chat \{key} (the latest entries first; older ones with before)\{more}."
}

///|
/// `afresh`.
pub fn afresh(key : String, threads : Array[String]) -> String {
  let more = if threads.is_empty() {
    ""
  } else {
    ", and chat_history for \{chat_histories(threads)}"
  }
  "This is a new conversation: your earlier one in this session is no longer used. Before you act on what comes below, read back from it what you need: session_history with chat \{key} (the latest entries first; older ones with before)\{more}."
}

///|
/// `longChat`.
pub fn long_chat(count : Double, threads : Array[String]) -> String {
  let more = if threads.is_empty() {
    ""
  } else {
    " (chat_history for \{chat_histories(threads)}, older pages with before)"
  }
  "This chat is long (\{num_text(count)} messages), and most of it is no longer in front of you. Before you go on, read back what people said in it\{more}: their requests, decisions and corrections from the start. Check that what you are doing still follows them, so that you do not drift from what they asked."
}

///|
/// `LONG_CHAT`.
pub let long_chat_from : Int = 20

///|
/// `cleared`.
pub fn cleared(key : String, threads : Array[String]) -> String {
  let more = if threads.is_empty() { "" } else { ": chat_history for \{chat_histories(threads)}" }
  "People cleared your context: this is a new conversation in the same chat, and your earlier one in this session is no longer loaded. Read the chat back before you act on what comes below\{more}. Your earlier work (session_history with chat \{key}) is not to be read back by default: only when you need something from it."
}

///|
/// A value as a template says it (`${v}`).
fn said(v : J?) -> String {
  match v {
    None => "undefined"
    Some(Null) => "null"
    Some(Str(s)) => t(s)
    Some(Num(n)) => num_text(n)
    Some(Bool(true)) => "true"
    Some(Bool(false)) => "false"
    Some(Arr(items)) => items.map(x => if x is Null { "" } else { said(Some(x)) }).join(",")
    Some(Obj(_)) => "[object Object]"
  }
}

///|
/// `backgroundStopped`: `tasks` the runtime's BackgroundTask rows, `resumable` the subagents SendMessage takes up.
pub fn background_stopped(tasks : Array[J], resumable : Array[String]) -> String {
  let lines = tasks.map(task => {
    let t0 = Some(task)
    let id = said(get(t0, "id"))
    let kind = if is_s(get(t0, "kind"), "agent") { "subagent" } else { "background command" }
    let description = get(t0, "description")
    let about = if is_s(description, "") { "" } else { " (\{said(description)})" }
    let again = if resumable.contains(id) { ": SendMessage to it goes on from where it stopped" } else { "" }
    "- \{kind} \{id}\{about}\{again}"
  })
  "The station ended your earlier process (people stopped you, or it moved this session to another account, took a change to it or started it again), and the work it had going in the background was stopped with it. None of it will report back:\n\{lines.join("\n")}\nBefore you wait on any of it, check where each got to and start again what is still needed."
}

///|
/// `waitOver`.
pub fn wait_over(seconds : Double) -> String {
  "You said you were waiting on work you started (\{num_text(seconds)} seconds), and nothing has brought you back yet. Check on it now.\n- If it is done: pick up its results and carry on. If nothing was watching it (you would have been told when it ended), start a watch the next time instead of waiting on a guessed duration.\n- If it is still running: make sure something will tell you when it ends or fails (a background command or agent, a job with watch, a loop polling CI that exits on the first failure), do whatever else you can meanwhile, and only then chat_state \"waiting\" again. If it truly cannot be watched, wait the shortest it could still take.\n- If it has stopped or is stuck: say so in the thread, and fix or restart it if you can."
}

///|
/// `continuedHere`.
pub fn continued_here(instructions : String) -> String {
  "This session began in a terminal and now goes on in still.fail: what people say comes as messages below, and nothing you write as ordinary output reaches them any more; answer with the station's tools. How still.fail works, from now on:\n\n<stillfail-instructions>\n\{instructions}\n</stillfail-instructions>"
}

///|
/// `threadAddress`.
pub fn thread_address(channel : String, thread_ts : String) -> String {
  "\{channel}/\{thread_ts}"
}

///|
fn is_feishu_chat(s : String) -> Bool {
  s.has_prefix("oc_") && s.length() > 3 && all_units(sub(s, 3), is_alnum)
}

///|
fn is_feishu_message(s : String) -> Bool {
  let rest = if s.has_prefix("omt_") {
    Some(sub(s, 4))
  } else if s.has_prefix("om_") {
    Some(sub(s, 3))
  } else {
    None
  }
  rest is Some(r) && r != "" && all_units(r, is_alnum)
}

///|
/// `parseThreadAddress`.
pub fn parse_thread_address(value : String) -> (String, String)? {
  let v = trim(value)
  let at = index_of(v, "/")
  if at < 0 {
    return None
  }
  let channel = sub(v, 0, to=at)
  let ts = sub(v, at + 1)
  if is_feishu_chat(channel) && is_feishu_message(ts) {
    return Some((channel, ts))
  }
  // A group connect's: its space's id, twice for its lobby, or with a topic's (src/group: a space's stream is a thread).
  let space = channel.length() == 26 &&
    (channel.has_prefix("d_") || channel.has_prefix("s_")) &&
    all_units(sub(channel, 2), is_hex_lower)
  let topic = ts.length() == 18 && ts.has_prefix("t_") && all_units(sub(ts, 2), is_hex_lower)
  if space && (ts == channel || topic) {
    return Some((channel, ts))
  }
  let dot = index_of(ts, ".")
  if dot < 0 {
    return None
  }
  let secs = sub(ts, 0, to=dot)
  let micros = sub(ts, dot + 1)
  let ok = channel != "" &&
    all_units(channel, c => is_upper(c) || is_digit(c)) &&
    secs != "" &&
    all_units(secs, is_digit) &&
    micros != "" &&
    all_units(micros, is_digit)
  if ok {
    Some((channel, ts))
  } else {
    None
  }
}

///|
fn escape_attr(value : String) -> String {
  replace_all(replace_all(value, "&", "&amp;"), "\"", "&quot;")
}

///|
/// A JavaScript value's truth (`if (v)`).
fn truthy(v : J?) -> Bool {
  match v {
    None | Some(Null) | Some(Bool(false)) => false
    Some(Str(s)) => s.length() > 0
    Some(Num(n)) => n != 0.0 && !n.is_nan()
    _ => true
  }
}

///|
fn find_attachment(m : J?, name : J?) -> J? {
  for a in arr(get(m, "attachments")) {
    if same(get(Some(a), "name"), name) {
      return Some(a)
    }
  }
  None
}

///|
fn is_pasted(name : String) -> Bool {
  if !name.has_prefix("pasted-text-") || !name.has_suffix(".txt") {
    return false
  }
  let middle = sub(name, 12, to=name.length() - 4)
  middle.length() == 36 && all_units(middle, c => is_hex_lower(c) || c == '-'.to_int())
}

///|
/// `messageForAgent`: a message's words as the agent reads them: quotes, then the words, then the files as paths.
pub fn message_for_agent(m : J) -> String {
  let msg = Some(m)
  let again : Array[String] = []
  let parts = arr(get(msg, "quotes")).map(quote_j => {
    let q = Some(quote_j)
    let role = get(q, "role")
    let file = get(q, "file")
    let author = said(get(q, "author"))
    let whose = if is_s(role, "agent") {
      "your own earlier message"
    } else if is_s(role, "page") {
      let shot = if truthy(file) { find_attachment(msg, file) } else { None }
      match shot {
        Some(s) =>
          "a web page shown in the chat's preview (\{author}), marked with its number in its own screenshot \{said(get(Some(s), "path"))}"
        None =>
          "a web page shown in the chat's preview (\{author}), marked with its number in the attached screenshot"
      }
    } else if is_s(role, "image") {
      "an image marked in the chat (\{author}), its number pinned on the marked image attached"
    } else {
      "a message from \{author}"
    }
    let ts = get(q, "ts")
    let mut which = match ts {
      None | Some(Null) => whose
      _ => "\{whose} \{said(ts)} in this conversation"
    }
    let quoted = if truthy(file) && !is_s(role, "page") && !is_s(role, "image") {
      find_attachment(msg, file)
    } else {
      None
    }
    if quoted is Some(a) {
      let path = said(get(Some(a), "path"))
      which = which + ", its file \{path} (sent with that message, not again)"
      again.push(path)
    }
    let passage = said(get(q, "text")).split("\n").map(l => "> \{l}").collect()
    let comment = if is_s(get(q, "comment"), "") {
      ""
    } else {
      "\nTheir comment on it: \{said(get(q, "comment"))}"
    }
    "[Quote] From \{which}:\n\{passage.join("\n")}\{comment}"
  })
  parts.push(said(get(msg, "text")))
  let attachments = arr(get(msg, "attachments"))
  let pasted = attachments.filter(a => is_pasted(said(get(Some(a), "name"))))
  if pasted.length() > 0 {
    parts.push(
      "The user pasted text into the composer; its full contents are in these text attachments. Read them as part of the user's message:\n\{pasted.map(a => "- \{said(get(Some(a), "path"))}").join("\n")}",
    )
  }
  let attached = attachments.filter(a => !again.contains(said(get(Some(a), "path"))))
  if attached.length() > 0 {
    let lines = attached.map(a => {
      let x = Some(a)
      "- \{said(get(x, "path"))} (\{said(get(x, "name"))}, \{said(get(x, "size"))} bytes)"
    })
    parts.push("Attached files:\n\{lines.join("\n")}")
  }
  parts.filter(p => p != "").join("\n\n")
}

///|
fn via(surface : String) -> String {
  if surface == stillfail_surface {
    "web"
  } else if surface.has_prefix("feishu:") {
    "feishu"
  } else if surface.has_prefix("comma:") {
    "comma"
  } else if surface.has_prefix("group:") {
    "group"
  } else {
    "slack"
  }
}

///|
fn client_attr(m : J?) -> String {
  match get(m, "client") {
    None | Some(Null) => ""
    c => " client=\"\{escape_attr(said(c))}\""
  }
}

///|
/// `/^\d{10}(?:\.\d+)?$/`.
fn seconds_id(ts : String) -> Bool {
  let dot = index_of(ts, ".")
  let secs = if dot < 0 { ts } else { sub(ts, 0, to=dot) }
  let frac = if dot < 0 { None } else { Some(sub(ts, dot + 1)) }
  secs.length() == 10 &&
  all_units(secs, is_digit) &&
  (match frac {
    None => true
    Some(f) => f != "" && all_units(f, is_digit)
  })
}

///|
fn finite(n : Double) -> Bool {
  !n.is_nan() && !n.is_inf()
}

///|
fn time_attr(m : J?, surface : String) -> String {
  let ts = said(get(m, "ts"))
  let kind = via(surface)
  let numeric = if kind != "comma" && kind != "feishu" && kind != "group" && seconds_id(ts) {
    (try @string.parse_double(ts) catch { _ => @double.not_a_number }) * 1000.0
  } else {
    @double.not_a_number
  }
  let sent = if finite(numeric) && numeric <= 8.64e15 { Some(numeric) } else { None }
  let recorded = match get(m, "createdAt") {
    Some(Num(c)) if finite(c) && c > 0.0 && c <= 8.64e15 => Some(c)
    _ => None
  }
  let at = match sent {
    Some(s) => Some(s)
    None => recorded
  }
  match at {
    None => ""
    Some(a) => " \{if sent is None { "recorded_at" } else { "sent_at" }}=\"\{iso_date(a)}\""
  }
}

///|
fn lookup(pairs : Array[(String, String)], key : String) -> String? {
  for p in pairs {
    if p.0 == key {
      return Some(p.1)
    }
  }
  None
}

///|
/// What a card's change is told with a message it came with (`formatInbound`'s `cards`).
pub(all) struct CardChange {
  ended_author : String
  ended_ts : String
  current_ts : String?
  special : String?
}

///|
/// `formatInbound`: messages handed to a session, each with its source and sender, and a hint where a thread is new to
/// it. `posts` and `cards` by the message's index in `messages`.
pub fn format_inbound(
  messages : Array[J],
  new_threads : Array[Double],
  names : Array[(String, String)],
  selves : Array[(String, String)],
  posts? : Map[Int, String] = {},
  cards? : Map[Int, CardChange] = {},
  self_key? : String = "",
) -> String {
  let lines = []
  let hinted : Array[Double] = []
  for i, p0 in messages {
    let p = Some(p0)
    let m = get(p, "message")
    let surface = said(get(p, "surface"))
    let address = thread_address(said(get(p, "channel")), said(get(p, "threadTs")))
    let thread = num_of(get(m, "thread")).unwrap_or(@double.not_a_number)
    let n = num_of(get(m, "n")).unwrap_or(0.0)
    let before = n > 1.0 || (surface != stillfail_surface && !same(get(m, "ts"), get(p, "threadTs")))
    if new_threads.contains(thread) && before && !hinted.contains(thread) {
      hinted.push(thread)
      lines.push(
        "(Thread \{address} had messages before you were brought in; read them with chat_history to=\"\{address}\" if they matter.)",
      )
    }
    let you = match lookup(selves, said(get(p, "connect"))) {
      Some(s) => " you=\"\{escape_attr(s)}\""
      None => ""
    }
    let agent = is_s(get(m, "authorKind"), "agent")
    let author = said(get(m, "author"))
    let name = lookup(names, author)
    let from = if agent {
      name.unwrap_or("another agent")
    } else {
      match name {
        Some(nm) => "\{nm} (\{author})"
        None => author
      }
    }
    let sent_before = match posts.get(i) {
      Some(post) => " before=\"\{escape_attr(post)}\""
      None => ""
    }
    lines.push(
      "<message via=\"\{via(surface)}\" connect=\"\{escape_attr(said(get(p, "connect")))}\"\{you} thread=\"\{address}\"\{time_attr(m, surface)} from=\"\{escape_attr(from)}\"\{if agent { " bot" } else { "" }}\{client_attr(m)} ts=\"\{said(get(m, "ts"))}\"\{sent_before}>\n\{message_for_agent(m.unwrap_or(Null))}\n</message>",
    )
    if cards.get(i) is Some(change) {
      let whose = if change.ended_author == self_key { "Your card" } else { "A card" }
      let now = match change.current_ts {
        None => "No newer card is pending."
        Some(ts) => "A newer card (message ts \{ts}) is pending; the person may not have seen it."
      }
      let next = if change.ended_author != self_key {
        "The agent that posted it can decide whether to ask again."
      } else {
        match change.special {
          Some(s) => "The underlying login or authorization may still be pending. \{s}"
          None => "If the decision is still needed and no newer card asks it, ask again with a new card."
        }
      }
      lines.push(
        "<card-state thread=\"\{escape_attr(address)}\" ts=\"\{escape_attr(change.ended_ts)}\">\{whose} is no longer pending after this message. The message is not necessarily a decision; read what it says. \{now} \{next}</card-state>",
      )
    }
  }
  lines.join("\n")
}

///|
/// `agoWords`: minutes up to an hour, hours and minutes up to a day, then days and hours.
pub fn ago_words(ms : Double) -> String {
  let minutes = ((if ms > 0.0 { ms } else { 0.0 }) / 60000.0).floor()
  if minutes < 1.0 {
    return "less than a minute"
  }
  if minutes < 60.0 {
    return "\{num_text(minutes)} min"
  }
  let hours = (minutes / 60.0).floor()
  let rest = minutes - hours * 60.0
  if hours < 24.0 {
    return if rest == 0.0 { "\{num_text(hours)} h" } else { "\{num_text(hours)} h \{num_text(rest)} min" }
  }
  let days = (hours / 24.0).floor()
  let left = hours - days * 24.0
  if left == 0.0 {
    "\{num_text(days)} d"
  } else {
    "\{num_text(days)} d \{num_text(left)} h"
  }
}

///|
/// `text.replace(/\s+/g, " ")`.
fn spaces_one(text : String) -> String {
  let out = StringBuilder::new()
  let mut in_space = false
  for i in 0..<text.length() {
    let c = text.unsafe_charcode_at(i)
    if is_space(c) {
      if !in_space {
        out.write_char(' ')
      }
      in_space = true
    } else {
      out.write_string(sub(text, i, to=i + 1))
      in_space = false
    }
  }
  out.to_string()
}

///|
fn recalled(text : String) -> String {
  let line = code_points(trim(spaces_one(text)))
  if line.length() > 200 {
    line[0:200].to_array().join("") + "…"
  } else {
    line.join("")
  }
}

///|
/// `formatCardChoices`: what people chose on the agent's cards with an option that closes them, said before what it is
/// handed now (`now`, ms). Empty when none.
pub fn format_card_choices(choices : Array[J], names : Array[(String, String)], now : Double) -> String {
  if choices.is_empty() {
    return ""
  }
  let lines = choices.map(c0 => {
    let c = Some(c0)
    let who = said(get(c, "by"))
    let by = match lookup(names, who) {
      Some(nm) => "\{nm} (\{who})"
      None => who
    }
    let thread = match get(c, "where") {
      Some(Arr(w)) =>
        " thread=\"\{escape_attr(thread_address(said(w.get(0)), said(w.get(1))))}\""
      _ => ""
    }
    let card = match get(c, "ts") {
      None | Some(Null) => ""
      ts => " card=\"\{escape_attr(said(ts))}\""
    }
    let asked = match get(c, "question") {
      Some(Str(q)) if trim(t(q)) != "" => "Asked: \{recalled(t(q))}\n"
      _ => ""
    }
    let at = num_of(get(c, "at")).unwrap_or(@double.not_a_number)
    "<card-choice\{thread}\{card} by=\"\{escape_attr(by)}\" at=\"\{to_fixed(at / 1000.0, 6)}\" ago=\"\{ago_words(now - at)}\">\n\{asked}Chosen: \{said(get(c, "option"))}\n</card-choice>"
  })
  "[Earlier choices on your cards, told to you now. Each closed its card when it was made (at, ago) without sending you a message, so this is the first you hear of it. They are settled and not new: what you are handed after them is not about them unless it says so. Do not answer a choice by itself or ask it again.]\n\{lines.join("\n")}"
}

///|
/// `formatWidgetModels`: what people chose in widgets the agent posted; empty when none.
pub fn format_widget_models(models : Array[J]) -> String {
  if models.is_empty() {
    return ""
  }
  let lines = models.map(w0 => {
    let w = Some(w0)
    match get(w, "thread") {
      Some(Arr(th)) =>
        "- \{said(get(w, "name"))} in \{thread_address(said(th.get(0)), said(th.get(1)))}: \{said(get(w, "model"))}"
      _ => "- \{said(get(w, "name"))}: \{said(get(w, "model"))}"
    }
  })
  "A widget you posted has state for you (the person's choices in it; not a message to answer by itself):\n\{lines.join("\n")}"
}

///|
/// A card as chat_history says it (`formatHistory`'s `cards`, by the message's n).
pub(all) struct HistoryCard {
  card : J?
  pending : Bool
  chose : (String, J)?
}

///|
/// `formatHistory`: a thread's messages for chat_history.
pub fn format_history(
  messages : Array[J],
  surface : String,
  address : String,
  self_key : String,
  names : Array[(String, String)],
  cards? : Map[Double, HistoryCard] = {},
) -> String {
  messages
  .map(m0 => {
    let m = Some(m0)
    let kind = get(m, "authorKind")
    let author = said(get(m, "author"))
    let from = if is_s(kind, "agent") && author == self_key {
      "you"
    } else if is_s(kind, station_author) {
      "station"
    } else {
      match lookup(names, author) {
        Some(nm) => "\{nm} (\{author})"
        None => author
      }
    }
    let bot = if !is_s(kind, "person") && from != "you" { " bot" } else { "" }
    let n = num_of(get(m, "n")).unwrap_or(@double.not_a_number)
    let card = match cards.get(n) {
      None => ""
      Some(found) => {
        let c = found.card
        let facts = Fields::new()
        match get(c, "type") {
          None => ()
          Some(v) => facts.set("type", v)
        }
        if get(c, "options") is Some(Arr(_) as options) {
          facts.set("options", options)
        }
        if get(c, "placeholder") is Some(Str(_) as v) {
          facts.set("placeholder", v)
        }
        if get(get(c, "vault"), "request") is Some(Str(_) as v) {
          facts.set("request", v)
        }
        if get(get(c, "adb"), "request") is Some(Str(_) as v) {
          facts.set("phoneRequest", v)
        }
        if get(get(c, "signin"), "site") is Some(Str(_) as v) {
          facts.set("site", v)
        }
        if get(c, "login") is Some(Str(_) as v) {
          facts.set("login", v)
        }
        if get(c, "station") is Some(Str(_) as v) {
          facts.set("station", v)
        }
        let chose = match found.chose {
          None => ""
          Some((by, option)) =>
            "; \{by} chose \{stringify(option)}, which closed it without a message"
        }
        "\n[Answer card: \{if found.pending { "pending" } else { "no longer pending" }}\{chose}; \{stringify(facts.json())}]"
      }
    }
    "<message via=\"\{via(surface)}\" thread=\"\{address}\"\{time_attr(m, surface)} from=\"\{escape_attr(from)}\"\{bot}\{client_attr(m)} ts=\"\{said(get(m, "ts"))}\">\n\{message_for_agent(m0)}\{card}\n</message>"
  })
  .join("\n")
}
