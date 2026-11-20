// An agent archives another still.fail chat, here or on a station of its workspace (station/src/sessions/
// chat-archive.ts): a chat with its own session takes that session with it, a separate chat is hidden on its own, as
// the app does (lifecycle.ts `archiveChat`, the station's: `fn.archiveChat`).

///|
pub let archive_method = "session.archive"

///|
async fn Storage::archive_here(self : Storage, chat : String, ws : String?, caller : String?) -> String {
  let reference = if chat.contains("/o/") || chat.contains("/chats/") {
    match chat.find("?") {
      Some(at) => cut(chat, 0, end=at)
      None => chat
    }
  } else {
    chat
  }
  let thread = match self.named(reference, ws) {
    Thread(t) => t
    Session(k, _) => thread_of(self.session_thread_of(k))
  }
  if !self.thread_in(thread, ws) {
    raise failed("that chat is in another workspace: only this workspace's chats can be archived")
  }
  if str(thread, "surface") != Some(stillfail_surface) {
    raise failed("only still.fail chats can be archived with chat_archive")
  }
  match caller {
    Some(c) =>
      if get(thread_of(self.session_thread_of(c)), "id") == get(thread, "id") {
        raise failed("chat_archive is for another chat, not your own")
      }
    None => ()
  }
  let already = match str(thread, "home") {
    Some(h) =>
      match self.session(h) {
        Some(s) => str(s, "archivedBy") == Some(manual)
        None => false
      }
    None => str(thread, "hiddenBy") == Some(manual)
  }
  if already {
    return "Already archived: \{chat}."
  }
  self.st.hub.archive_chat(get(thread, "id").unwrap_or(Json::null()), true)
  "Archived \{chat}."
}

///|
pub async fn Storage::chat_archive(self : Storage, key : String, args : Json) -> String {
  let chat = match get(args, "chat") {
    Some(String(s)) => js_trim(s)
    _ => ""
  }
  if chat == "" {
    raise failed("chat is required: another chat's link, thread address or session key")
  }
  guard self.elsewhere(key, chat) is Some(station) else { return self.archive_here(chat, self.scope_of(key), Some(key)) }
  guard self.peers_of(key) is Some(call) else { raise failed("other stations cannot be reached from this one yet") }
  let answer = call(station, jo([("method", js(archive_method)), ("session", js(key)), ("chat", js(chat))])) catch {
    e => {
      let why = message_of(e)
      if is_kind(e, "Refused") && from_before(why) {
        raise failed("station \{station} is not updated yet: its chats cannot be archived from here")
      }
      raise failed("archive request to station \{station} failed: \{why}. It may already be archived; call chat_archive again with the same chat")
    }
  }
  guard str(answer, "text") is Some(text) else { raise failed("station \{station} answered without an archive result") }
  text
}

///|
/// A station of the workspace asks to archive one of its chats here.
pub async fn Storage::archive_for_peer(self : Storage, request : Json, ws : String?) -> Json {
  let chat = match get(request, "chat") {
    Some(String(s)) => js_trim(s)
    _ => ""
  }
  if chat == "" {
    raise failed("chat is required")
  }
  jo([("text", js(self.archive_here(chat, ws, None)))])
}
