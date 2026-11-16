// What a chat's cards and buttons do (slice 8: still.fail apps/android chat/screens/Decisions.kt DecisionUnder, OptionButton;
// Chat.kt AskDismiss, ArchiveUnder, archiveChat; LoginCards.kt; AppState.kt act, isDoing). The
// chat's sheets (sheets.mbt) are the library's presenters'. What is done is said to
// the core as the Android app says it, under way on its button (a spinner), said in a toast when it could not be;
// nothing with MBUI_READONLY=1.

///|
/// What this slice keeps while the app runs.
priv struct Decide {
  /// asks let go here, before the core says so, by station, thread and post
  gone : Map[String, Bool]
  /// the chats whose letters were read for their sheet (the core's `chatLetters`), by station and session: their
  /// threads, let go as the chat is (chat.mbt chat_left)
  letters_held : Map[String, Double]
  /// a job's sheet: what it said (0) or its output (1)
  mut job_tab : Int
  /// groups and steps of a history opened, by their key
  opened : @sf.LiveMap[String, Bool]
}

///|
let dui : Decide = {
  gone: {},
  letters_held: {},
  job_tab: 0,
  opened: @sf.LiveMap::new(),
}

///|
/// As at the start (tests).
fn decide_reset() -> Unit {
  dui.gone.clear()
  dui.letters_held.clear()
  dui.job_tab = 0
  history_tab.set(0)
  dui.opened.clear()
  history_placed.clear()
  history_short.clear()
}

///|
/// The chat into the archive (its bar's 归档, the one under its last 做完了, its sheet's): Home at
/// once, the chat gone from the list (the core's), said at once by its title, or why not.
fn archive_chat(src : Source, r : ChatRef, v : ChatView) -> Unit {
  home()
  let p : Map[String, Json] = {
    "station": Json::string(r.station),
    "session": Json::string(r.session),
    "archived": Json::boolean(true),
  }
  match v.thread {
    Some(th) => p["thread"] = Json::number(th)
    None => ()
  }
  act(
    src,
    tr("android-chat.archive.verb"),
    "archive/" + r.station + "/" + r.session,
    "chat.archive",
    Json::object(p),
    done=@sf.t("web-main.chat.archivedNamed", args=[("title", v.title)]),
    done_action=tr("android-chat.archived.undo"),
    done_run=@sfbase.archive_undo(src, p),
    at_once=true,
  )
}
