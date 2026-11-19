// adb/title.ts, with what it names a chat by (read/views.ts `titleOf`, `given`: client/core-ts/src/titles.ts).

///|
/// titles.ts `withoutMentions`: text without Slack's `<@U123>` mentions.
fn without_mentions(text : String) -> String {
  let out = StringBuilder::new()
  let mut rest = text
  while rest.find("<@") is Some(at) {
    out.write_string(js_slice(rest, 0, b=at))
    let after = js_slice(rest, at + 2)
    match after.find(">") {
      Some(end) if end > 0 &&
        js_slice(after, 0, b=end)
        .iter()
        .all(c => (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) =>
        rest = js_slice(after, end + 1)
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
/// A field of a thread's row as a title reads it: a string trimmed of white space, else "".
fn titled(t : J, k : String) -> String {
  match at(Some(t), k) {
    Some(Str(u)) => @jscase.trim_white(@jsjson.sanitize_str(u))
    _ => ""
  }
}

///|
/// titles.ts `givenTitle`: the name people gave a chat, else its agent's; None where neither did.
pub fn given_title(t : J) -> String? {
  let given = titled(t, "title")
  if given != "" {
    return Some(given)
  }
  let auto = titled(t, "autoTitle")
  if auto != "" {
    Some(auto)
  } else {
    None
  }
}

///|
/// titles.ts `chatTitle`.
pub fn chat_title(
  t : J,
  first_text : String?,
  channel_name : String?,
  untitled : String,
  direct : String,
) -> String {
  if given_title(t) is Some(g) {
    return g
  }
  let surface = text_of(at(Some(t), "surface"))
  if at(Some(t), "surface") is Some(Str(_)) &&
    (surface == "chat" || surface == "ember" || surface == "stillfail") {
    return untitled
  }
  for line in without_mentions(first_text.unwrap_or("")).split("\n") {
    let words = @jscase.split_by(line.to_owned(), @jscase.is_white_space).filter(w => {
        w != ""
      },
    )
    let joined = words.join(" ")
    if joined != "" {
      return joined
    }
  }
  let name = @jscase.trim_white(channel_name.unwrap_or(""))
  if name != "" {
    return if surface.has_prefix("feishu:") || surface.has_prefix("group:") {
      name
    } else {
      "#" + name
    }
  }
  if titled(t, "channel").has_prefix("D") {
    return direct
  }
  untitled
}

///|
/// views.ts `titleOf`, in the words of the request being read (`spokenLang`): outside one, as a grant is named,
/// Chinese, whatever the station's own language.
pub fn World::title_of(
  self : World,
  thread : J,
  first_text : String?,
) -> String {
  chat_title(
    thread,
    first_text,
    None,
    self.tr("zh", "station.chat.untitled"),
    self.tr("zh", "station.chat.directMessage"),
  )
}

///|
/// rows.ts STILLFAIL_SURFACE.
pub let stillfail_surface : String = "chat"

///|
/// title.ts `grantChatTitle`: the grant named by its original chat if that chat is still a member of the session.
pub async fn grant_chat_title(w : World, r : J) -> String? {
  let chat = text_of(at(Some(r), "chat"))
  let session = get(r, "session")
  let own = match chat.find("/") {
    None => J::Null
    Some(slash) => {
      let st = w.store("sessionThread", [
        session,
        js(js_slice(chat, 0, b=slash)),
        js(js_slice(chat, slash + 1)),
      ])
      get(st, "thread")
    }
  }
  if !(own is Null) {
    let without_text = w.title_of(own, None)
    // A given name and a still.fail chat's name do not depend on the session's most recent chat.
    let surface = str_of(at(Some(own), "surface"))
    if given_title(own) is Some(_) ||
      surface == Some(stillfail_surface) ||
      surface == Some("stillfail") {
      return Some(without_text)
    }
    let first = str_of(Some(w.store("firstText", [get(own, "id")])))
    let with_text = w.title_of(own, first)
    if with_text == without_text {
      return Some(without_text)
    }
    let latest = w.store("sessionChat", [session])
    return Some(
      if jeq(get(get(latest, "thread"), "id"), get(own, "id")) &&
        !(latest is Null) {
        with_text
      } else {
        without_text
      },
    )
  }
  let latest = w.store("sessionChat", [session])
  if latest is Null {
    None
  } else {
    Some(
      w.title_of(get(latest, "thread"), str_of(Some(get(latest, "firstText")))),
    )
  }
}
