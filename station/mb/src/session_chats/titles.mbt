// A chat named by its agent (station/src/sessions/titles.ts, chat_post's title): the first name at once, a new one when
// the talk has moved on, never over a name people gave it.

///|
let title_longest : Int = 30

///|
let said_before_change : Double = 5.0

///|
let title_changes : Double = 2.0

///|
/// `/\s+/u` split with the empty parts dropped.
fn words_of(s : String) -> Array[String] {
  @jscase.split_by(s, is_js_space).filter(w => w != "")
}

///|
/// A title as a chat shows it: one line, spaces collapsed, no closing full stop, at most 30 characters.
pub fn clean_title(title : String) -> String {
  let line = words_of(title).join(" ")
  let mut end = line.length()
  while end > 0 && (line.unsafe_charcode_at(end - 1) == '.' || line.unsafe_charcode_at(end - 1) == '。') {
    end -= 1
  }
  let trimmed = trim_end(slice(line, 0, b=end))
  trim_end(first_chars(trimmed, title_longest))
}

///|
/// Names `thread` `given` as its agent asked; what came of it, for the agent.
pub async fn name_chat(w : World, thread : J, given : String) -> String {
  let title = clean_title(given)
  if title == "" {
    return ""
  }
  let id = at(Some(thread), "id").unwrap_or(Null)
  match may_name(w, id, title) {
    Err(why) => " Title not changed: \{why}."
    Ok(false) => ""
    Ok(true) => {
      apply_title(w, id, title)
      " Titled the chat \"\{title}\"."
    }
  }
}

///|
/// The chat session `key` last heard from, as its address, when it has no name and nobody is at work in it.
pub async fn untitled_chat(w : World, key : String) -> String? {
  let latest = w.store("latestThread", [js(key)])
  let thread = at(Some(latest), "thread")
  guard thread is Some(Obj(_)) else { return None }
  if !nullish(at(thread, "hiddenAt")) {
    return None
  }
  let title = str_of(at(thread, "title"))
  if (title is Some(t) && trim(t) != "") || !nullish(at(thread, "autoTitle")) {
    return None
  }
  let id = at(thread, "id").unwrap_or(Null)
  if w.store("firstText", [id]) is Null {
    return None
  }
  let members = arr_of(Some(w.store("threadSessions", [id]))).unwrap_or([])
  let mut at_work = false
  for m in members {
    let session = str_of(at(Some(m), "session")).unwrap_or("")
    if session == key {
      continue
    }
    let last = w.store("lastTurn", [js(session)])
    let running = str_of(Some(w.hub("processState", [js(session)]))) == Some("running")
    let busy = running ||
      w.store("hasPending", [js(session)]) is Bool(true) ||
      (last is Obj(_) && (nullish(at(Some(last), "endedAt")) || str_of(at(Some(last), "declared")) == Some("waiting")))
    if busy {
      at_work = true
      break
    }
  }
  if at_work {
    None
  } else {
    Some("\{str_of(at(thread, "channel")).unwrap_or("")}/\{str_of(at(thread, "threadTs")).unwrap_or("")}")
  }
}

///|
/// Whether `title` may name the chat now (false: it already does), or why not.
async fn may_name(w : World, thread : J, title : String) -> Result[Bool, String] {
  let row = w.store("getThread", [thread])
  guard row is Obj(_) else { return Err("the chat is gone") }
  if str_of(at(Some(row), "title")) is Some(t) && trim(t) != "" {
    return Err("people named this chat")
  }
  let given = w.store("autoTitle", [thread])
  let given_title = str_of(at(Some(given), "title"))
  guard given_title is Some(gt) else { return Ok(true) }
  if gt == title {
    return Ok(false)
  }
  if num_of(at(Some(given), "changes")).unwrap_or(0.0) >= title_changes {
    return Err("it has been changed as often as it may be")
  }
  let said = num_of(
      Some(w.store("peopleSaidAfter", [thread, at(Some(given), "n").unwrap_or(Null), jn(said_before_change)])),
    ).unwrap_or(0.0)
  if said < said_before_change && !(w.store("hasActiveWatch", [thread]) is Bool(true)) {
    return Err(
      "people have said too little since it was given; change it only when it no longer says what the chat is about",
    )
  }
  Ok(true)
}

///|
async fn apply_title(w : World, thread : J, title : String) -> Unit {
  let changed = !(at(Some(w.store("autoTitle", [thread])), "title") is Some(Null))
  w.store("setAutoTitle", [thread, js(title), jb(changed)]) |> ignore
}

///|
/// titles.ts `withoutMentions`: text without Slack's `<@U123>` mentions.
fn without_mentions(text : String) -> String {
  let out = StringBuilder::new()
  let mut rest = text
  while rest.find("<@") is Some(i) {
    out.write_string(slice(rest, 0, b=i))
    let after = slice(rest, i + 2)
    match after.find(">") {
      Some(end) if end > 0 &&
        slice(after, 0, b=end)
        .iter()
        .all(c => (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) =>
        rest = slice(after, end + 1)
      _ => {
        out.write_string("<@")
        rest = after
      }
    }
  }
  out.write_string(rest)
  out.to_string()
}

///|
fn titled_field(t : J, k : String) -> String {
  match str_of(at(Some(t), k)) {
    Some(s) => @jscase.trim_white(s)
    None => ""
  }
}

///|
/// titles.ts `givenTitle`: the name people gave a chat, else its agent's; None where neither did.
fn given_title(t : J) -> String? {
  let g = titled_field(t, "title")
  if g != "" {
    return Some(g)
  }
  let auto = titled_field(t, "autoTitle")
  if auto != "" {
    Some(auto)
  } else {
    None
  }
}

///|
/// views.ts `titleOf` / titles.ts `chatTitle`.
fn title_of(w : World, t : J, first_text : String?, channel_name : String?) -> String {
  if given_title(t) is Some(g) {
    return g
  }
  let untitled = w.words.tr("zh", "station.chat.untitled")
  let surface = str_of(at(Some(t), "surface")).unwrap_or("")
  if at(Some(t), "surface") is Some(Str(_)) &&
    (surface == "chat" || surface == "ember" || surface == "stillfail") {
    return untitled
  }
  for line in without_mentions(first_text.unwrap_or("")).split("\n") {
    let joined = @jscase.split_by(line.to_owned(), @jscase.is_white_space)
      .filter(s => s != "")
      .join(" ")
    if joined != "" {
      return joined
    }
  }
  let name = @jscase.trim_white(channel_name.unwrap_or(""))
  if name != "" {
    return if starts(surface, "feishu:") || starts(surface, "group:") {
      name
    } else {
      "#" + name
    }
  }
  if starts(titled_field(t, "channel"), "D") {
    return w.words.tr("zh", "station.chat.directMessage")
  }
  untitled
}
