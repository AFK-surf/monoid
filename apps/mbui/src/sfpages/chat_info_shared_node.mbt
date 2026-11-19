// What a chat's info says of it, worked out once for every screen: 小屏's sheet (sfapp sheets.mbt chat_info_node) and
// 中屏's and 大屏's panel (sfdesk chat_info_node.mbt) each lay it out their way over the same reading of the chat's
// head: where it came from (Comma, Feishu, Slack), who started it, and what is in it (its pull requests, what else was
// said, the stations' files, the letters its agents and other chats' wrote); and its rename, the core's `chat.rename`.

///|
/// Where a chat came from, as its info names it (its thread's surface, its place, a Feishu link).
#derive(Eq)
pub(all) enum ChatThrough {
  Comma
  Feishu
  Slack
}

///|
/// Where chat `chat` (its head, as the core's `chat` says it) came from: a Comma Task's (Comma alone, in no place),
/// a Feishu chat's (its thread's surface, or a link to it), else Slack's where it is in a place; none where it is
/// still.fail's own (no place, no surface of another).
pub fn chat_through(chat : Json?) -> ChatThrough? {
  let surface = text(field(chat, "thread"), "surface")
  let place = text(chat, "place")
  if surface.has_prefix("comma:") {
    Some(Comma)
  } else if place == "" {
    None
  } else if surface.has_prefix("feishu:") || text(chat, "feishuUrl") != "" {
    Some(Feishu)
  } else {
    Some(Slack)
  }
}

///|
/// Who started the chat whose thread is `thread`, as its info names them: the name they are shown by, else the one
/// they have; "" where it is not said.
pub fn chat_creator_said(thread : Json?) -> String {
  let creator = field(thread, "creator")
  match text(field(creator, "shown"), "display") {
    "" => text(creator, "name")
    d => d
  }
}

///|
/// What is in a chat as its info lists it (chat_holds_said): its thread (none before it has one), its pull requests,
/// how much else was said in it, whether the workspace's stations lend their files, how many letters.
#derive(Eq)
pub(all) struct ChatHolds {
  thread : Double?
  pulls : Array[Json]
  said : Int
  files : Bool
  letters : Int
}

///|
/// Whether it holds anything to show (else the info shows no part of it).
pub fn ChatHolds::any(self : ChatHolds) -> Bool {
  self.pulls.length() > 0 || self.said > 0 || self.files || self.letters > 0
}

///|
/// What is in chat `r` as its head `chat` says it (ChatHolds): what is in its thread (things_now; none before it has
/// one), its letters (only once it has a thread), and the files of its workspace's stations (their rows, read as every
/// list reads them: sfbase's dv_stations).
pub fn chat_holds_said(src : Source, r : ChatRef, chat : Json?) -> ChatHolds {
  let thread = opt_number(field(chat, "thread"), "id")
  let (said, pulls) = match thread {
    Some(th) => things_now(src, r.station, th)
    None => (0, [])
  }
  let letters = if thread is Some(_) { number(chat, "letters").to_int() } else { 0 }
  let files = @sfbase.dv_stations(src, workspace_of(r.station)).0.unwrap_or([]).iter().any(fn(s) { s.drive })
  { thread, pulls, said, files, letters }
}

///|
/// Chat `station`/`session` (of thread `thread`, where it has one) renamed `title`: the core's `chat.rename`, as every
/// way to rename it asks it (its info's ✎, a row's 重命名).
pub fn chat_rename_call(src : Source, station : String, session : String, thread : Double?, title : String) -> Unit {
  let p : Map[String, Json] = {
    "station": Json::string(station),
    "session": Json::string(session),
    "title": Json::string(title),
  }
  match thread {
    Some(th) => p["thread"] = Json::number(th)
    None => ()
  }
  act(src, @sf.t("android-chat.rename.verb"), "", "chat.rename", Json::object(p))
}
