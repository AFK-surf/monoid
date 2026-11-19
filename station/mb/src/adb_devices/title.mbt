// adb/title.ts, with what it names a chat by (read/views.ts `titleOf`, `given`: client/core-ts/src/titles.ts).

///|
/// titles.ts `givenTitle`: the name people gave a chat, else its agent's; None where neither did.
pub fn given_title(t : J) -> String? {
  @session_chats.given_title(t)
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
  @session_chats.chat_title(t, first_text, channel_name, untitled, direct)
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
