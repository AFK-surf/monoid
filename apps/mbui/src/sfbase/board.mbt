// The chats as a board (看板), a way of showing Home's chats beside the list (列表): the workspace's chats in columns
// by where each stands (待派发, 等你处理, 进行中, 待收口, 监控中), by the station it runs on, or by who is in it. What a
// chat stands at is the core's (its row's state, tone, lead): the board only sorts by it, so a card goes to another
// column only as its chat goes on. Whether a workspace shows its board and how it is grouped are this device's, kept in
// the core's prefs (`boardViews`, `boardGroups`, `boardShowEmpty`) by workspace; the drafts of its 待派发 are the person's,
// the same on all their devices (the core's `boardDrafts` topic, written by `board.drafts`); what was chosen here shown
// at once while the core takes it. A draft started becomes a chat as a new chat's page makes one
// (`newChat.create` under the draft's key, then `chat.send` of its words), its card that chat's from the press on.

///|
/// The card whose chat is open beside the board (a wide board's), none while the board has the room alone.
pub let board_pick : @signals.Signal[ChatRef?] = @signals.signal(None)

///|
/// The column a narrow board shows (its chips choose it).
pub let board_lane : @signals.Signal[String] = @signals.signal("wait")

///|
/// Whether 待派发's line to write a new one in is open at its top.
pub let board_adding : @signals.Signal[Bool] = @signals.signal(false)

///|
/// How wide the chat open beside a wide board is as its edge was dragged here (none: as the prefs keep it; 0 or less:
/// its own width again, the prefs' not read till they say so too), board_chat_w_of's.
// kept across runs: put back by board_reset as a run starts
let board_chat_w_here : @signals.Signal[Double?] = @signals.signal(None, same=fn(a, b) { a == b })

///|
/// How wide the chat beside a wide board is where nothing else is said, and how narrow and how wide its edge drags it
/// at most (the board's room beside it may leave less: sfpages' board_wide).
pub let board_chat_w_default : Double = 460.0

///|
pub let board_chat_least : Double = 360.0

///|
pub let board_chat_most : Double = 860.0

///|
/// The prefs' key the width of the chat beside a wide board is kept by (`sidebars`, the person's as a sidebar's width is:
/// no workspace before the line).
let board_chat_key : String = "\nboardChat"

///|
/// A line written down to start later (待派发): its key (`new:board-…`, the key its chat is made under), its words, the
/// station it is to run on, that station's name and the files held in its own composer.
#derive(Eq, Debug)
pub(all) struct BoardFile {
  id : String
  name : String
}

///|
#derive(Eq, Debug)
pub(all) struct BoardDraft {
  id : String
  title : String
  station : String
  station_name : String
  files : Array[BoardFile]
}

///|
/// A draft started and not yet the core's own (its chat made: `newChat.create` answered): the workspace it is of, the
/// draft, the key its chat is made under.
#derive(Eq, Debug)
pub(all) struct BoardStarted {
  ws : String
  draft : BoardDraft
  key : String
}

///|
/// The drafts started whose chats the core has not listed yet.
pub let board_started : @signals.Signal[Array[BoardStarted]] = @signals.signal([])

///|
/// What was chosen here of each workspace's board, by workspace, till the core's prefs say it too: shown or not.
// kept across runs: put back by board_reset as a run starts
let board_views_here : Map[String, Bool] = Map([])

///|
/// How each workspace's board was grouped here, by workspace (board_views_here's).
// kept across runs: put back by board_reset as a run starts
let board_groups_here : Map[String, String] = Map([])

///|
/// Whether each workspace's board shows its empty columns as chosen here, by workspace (board_views_here's).
// kept across runs: put back by board_reset as a run starts
let board_empty_here : Map[String, Bool] = Map([])

///|
/// Each workspace's drafts as written here, by workspace, shown till the core says what it made of them: once it
/// answered, the first value of its topic other than the one it had then (`seen`).
// kept across runs: put back by board_reset as a run starts
let board_drafts_here : Map[String, BoardHere] = Map([])

///|
priv struct BoardHere {
  drafts : Array[BoardDraft]
  mut seen : Json??
}

///|
/// The words each draft started here began its chat with, by that chat's row's key (`<station>/<key>`): its card's
/// title while the core's pending row says 新对话 (board_title_of).
// kept across runs: put back by board_reset as a run starts
let board_titles_here : Map[String, String] = Map([])

///|
/// The chats of drafts started here the core has listed, by their row's key: once listed, never stood in for again
/// (archived, it is gone, not back as the draft's card).
// kept across runs: put back by board_reset as a run starts
let board_seen_here : Map[String, Bool] = Map([])

///|
/// Told as what was chosen here changes (board_views_here, board_groups_here, board_drafts_here).
pub let board_rev : @signals.Signal[Int] = @signals.signal(0)

///|
/// How many drafts were written here in this run (their keys, with the time of day: never one of before).
// kept across runs: put back by board_reset as a run starts
let board_written : Ref[Int] = Ref(0)

///|
/// As at the start: nothing chosen here, nothing open or started.
pub fn board_reset() -> Unit {
  board_views_here.clear()
  board_groups_here.clear()
  board_empty_here.clear()
  board_drafts_here.clear()
  board_writing_here.clear()
  board_titles_here.clear()
  board_seen_here.clear()
  board_written.val = 0
  board_rev.set(0)
  board_started.set([])
  board_chat_w_here.set(None)
  board_transient_reset()
}

///|
/// What is open on the board or being written put away (another workspace come in view).
pub fn board_transient_reset() -> Unit {
  board_pick.set(None)
  board_adding.set(false)
  board_lane.set("wait")
}

///|
/// The columns by where a chat stands, in their order: their keys.
// kept across runs: a value (never changed)
pub let board_lanes : Array[String] = ["draft", "wait", "run", "done", "watch"]

///|
/// A column's words.
pub fn board_lane_words(lane : String) -> String {
  match lane {
    "draft" => @sf.t("web-main.board.lane.draft")
    "wait" => @sf.t("web-main.board.lane.wait")
    "run" => @sf.t("web-main.board.lane.run")
    "done" => @sf.t("web-main.board.lane.done")
    "watch" => @sf.t("web-main.board.lane.watch")
    _ => lane
  }
}

///|
/// Where chat `i` stands on the board, as the core works it out for the viewer (its row's `stage`, client/core-ts
/// chat-stage.ts: one rule with the bell's 待处理 and the sidebar's counts): it needs them (a message of theirs that did
/// not go, a card or a need they decide, gone wrong for them), keeping watch, at work (or asking a colleague), else
/// ended (the core says none: done).
pub fn board_lane_of(i : ChatItem) -> String {
  if i.unsent {
    "wait"
  } else {
    match i.stage {
      "wait" | "watch" | "run" => i.stage
      // (a core that says no stage: keeping watch or at work as its row says, else ended; a core of today says a stage
      // for every row but an ended one, so this never goes against it)
      _ if i.state_lead == "watch" => "watch"
      _ if i.state == "run" || i.pending || i.agents.is_empty() => "run"
      _ => "done"
    }
  }
}

///|
/// Of the chats `items` the board shows, those 待收口 holds the viewer may put away at once (归档已读), as the core says
/// (its `archiveRead`, client/core-ts chat-stage.ts): ended with nothing left in it and read (not pinned or kept, none
/// failed or stopped), and started by the viewer, since archiving takes a chat off the whole workspace's lists; while its
/// station is there to archive it.
pub fn board_archivable_settled(items : Array[ChatItem]) -> Array[ChatItem] {
  items.filter(fn(i) { board_lane_of(i) == "done" && i.archive_read && !i.pending && i.swipe_archive })
}

///|
/// The prefs' map `name`'s entry for workspace `ws`, as the core keeps it now.
fn board_kept(src : Source, name : String, ws : String) -> Json? {
  field(field(src.topic("prefs", {}).get().value, name), ws)
}

///|
/// A prefs' map's entry for workspace `ws` alone, as `prefs.set` takes it.
fn board_of_ws(ws : String, v : Json) -> Json {
  Json::object(Map::from_array([(ws, v)]))
}

///|
/// Whether workspace `ws` shows its chats as the board on this device (else its list).
pub fn board_on_of(src : Source, ws : String) -> Bool {
  guard board_feature.get() else { return false }
  board_rev.get() |> ignore
  match board_views_here.get(ws) {
    Some(on) => on
    None => board_kept(src, "boardViews", ws) is Some(String("board"))
  }
}

///|
/// Workspace `ws` shown as the board, or as its list, on this device (the prefs' `boardViews`).
pub fn set_board_on(src : Source, ws : String, on : Bool) -> Unit {
  board_views_here[ws] = on
  board_rev.set(board_rev.untracked() + 1)
  (src.call)(
    "prefs.set",
    { "boardViews": board_of_ws(ws, if on { Json::string("board") } else { Json::null() }) },
    answer_unread,
  )
}

///|
/// Whether the workspace in view shows its board.
pub fn board_on_now(src : Source) -> Bool {
  match workspace_in_view(src).0 {
    Some(w) => board_on_of(src, w.id)
    None => false
  }
}

///|
/// How workspace `ws`'s board is grouped: by where each chat stands (`state`), by its station (`station`), by who is in
/// it (`person`).
pub fn board_group_of(src : Source, ws : String) -> String {
  board_rev.get() |> ignore
  let g = match board_groups_here.get(ws) {
    Some(g) => g
    None =>
      match board_kept(src, "boardGroups", ws) {
        Some(String(g)) => g
        _ => "state"
      }
  }
  if g == "station" || g == "person" {
    g
  } else {
    "state"
  }
}

///|
/// Workspace `ws`'s board grouped as `g` says (the prefs' `boardGroups`, none for by state).
pub fn set_board_group(src : Source, ws : String, g : String) -> Unit {
  board_groups_here[ws] = g
  board_rev.set(board_rev.untracked() + 1)
  (src.call)(
    "prefs.set",
    { "boardGroups": board_of_ws(ws, if g == "state" { Json::null() } else { Json::string(g) }) },
    answer_unread,
  )
}

///|
/// Whether workspace `ws`'s board shows the columns with no card in them (else leaves them out: the prefs'
/// `boardShowEmpty` false).
pub fn board_show_empty_of(src : Source, ws : String) -> Bool {
  board_rev.get() |> ignore
  match board_empty_here.get(ws) {
    Some(on) => on
    None => !(board_kept(src, "boardShowEmpty", ws) is Some(False))
  }
}

///|
/// Workspace `ws`'s board showing its empty columns, or leaving them out (the prefs' `boardShowEmpty`, none for shown).
pub fn set_board_show_empty(src : Source, ws : String, on : Bool) -> Unit {
  board_empty_here[ws] = on
  board_rev.set(board_rev.untracked() + 1)
  (src.call)(
    "prefs.set",
    { "boardShowEmpty": board_of_ws(ws, if on { Json::null() } else { Json::boolean(false) }) },
    answer_unread,
  )
}

///|
/// What the core says of workspace `ws`'s drafts (its `boardDrafts` topic's `drafts`), as it is now.
fn board_drafts_told(src : Source, ws : String) -> Json? {
  field(src.topic("boardDrafts", { "scope": Json::string(ws) }).get().value, "drafts")
}

///|
/// The drafts of workspace `ws` as kept (newest first), started ones too.
fn board_drafts_kept(src : Source, ws : String) -> Array[BoardDraft] {
  board_rev.get() |> ignore
  let told = board_drafts_told(src, ws)
  match board_drafts_here.get(ws) {
    Some(here) =>
      match here.seen {
        Some(seen) if seen != told => board_drafts_here.remove(ws)
        _ => return here.drafts
      }
    None => ()
  }
  match told {
    Some(Array(a)) =>
      a
      .map(fn(d) -> BoardDraft {
        let one = Some(d)
        {
          id: text(one, "id"),
          title: text(one, "title"),
          station: text(one, "station"),
          station_name: text(one, "stationName"),
          files: items(one, "files").map(fn(f) { { id: text(Some(f), "id"), name: text(Some(f), "name") } }),
        }
      })
      .filter(fn(d) { d.id != "" && (d.title != "" || !d.files.is_empty()) })
    _ => []
  }
}

///|
/// Workspace `ws`'s drafts made `drafts` (newest first): shown so at once, given to the core as the board has them.
fn board_drafts_put(src : Source, ws : String, drafts : Array[BoardDraft]) -> Unit {
  let here : BoardHere = { drafts, seen: None }
  board_drafts_here[ws] = here
  board_rev.set(board_rev.untracked() + 1)
  let given = Json::array(
    drafts.map(fn(d) {
      let one : Map[String, Json] = {
        "id": Json::string(d.id),
        "title": Json::string(d.title),
        "station": Json::string(d.station),
        "stationName": Json::string(d.station_name),
      }
      if !d.files.is_empty() {
        one["files"] = Json::array(d.files.map(fn(f) { { "id": Json::string(f.id), "name": Json::string(f.name) } }))
      }
      Json::object(one)
    }),
  )
  (src.call)("board.drafts", { "workspace": Json::string(ws), "drafts": given }, fn(r) {
    match r {
      // (what the core made of it shown from its next value on)
      Ok(_) => here.seen = Some(@signals.untracked(fn() { board_drafts_told(src, ws) }))
      // (refused: what it keeps shown again)
      Err(_) =>
        if board_drafts_here.get(ws) is Some(now) && physical_equal(now, here) {
          board_drafts_here.remove(ws)
        }
    }
    board_rev.set(board_rev.untracked() + 1)
  })
}

///|
/// 待派发 of workspace `ws` as it shows: its drafts not started.
pub fn board_drafts_of(src : Source, ws : String) -> Array[BoardDraft] {
  let started = board_started.get()
  board_drafts_kept(src, ws).filter(fn(d) { !started.iter().any(fn(s) { s.draft.id == d.id }) })
}

///|
/// A new board task's key, also the key its chat will be made under.
pub fn board_next_id() -> String {
  board_written.val += 1
  "new:board-\{@hostapi.wall_ms().to_int64()}-\{board_written.val}"
}

///|
/// The model control of draft `id` (model_triple's `of`): what it is to run on, picked for it alone and kept by the
/// core apart from a new chat's (`board:<id>`), its chat made with it (`newChat.create` `of`).
pub fn board_pick_of(id : String) -> String {
  "board:" + id
}

///|
/// What was picked for draft `id` on `station` let go of: the draft deleted or never added.
pub fn board_pick_forget(src : Source, station : String, id : String) -> Unit {
  guard station != "" && !src.read_only else { return }
  (src.call)("pick.set", { "station": Json::string(station), "of": Json::string(board_pick_of(id)), "clear": Json::boolean(true) }, answer_unread)
}

///|
/// The task being written in 待派发 of each workspace: its key, kept while the board is away (a chat or the list shown
/// in its place, the board made again as it comes back), so that its words and pictures, the core's composer's under
/// it, are there again; a new one only once it is added or put away (board_writing_renew).
// kept across runs: put back by board_reset as a run starts
let board_writing_here : Map[String, String] = Map([])

///|
/// The key of the task being written in 待派发 of workspace `ws` (board_writing_here's).
pub fn board_writing_id(ws : String) -> String {
  match board_writing_here.get(ws) {
    Some(id) => id
    None => board_writing_renew(ws)
  }
}

///|
/// The task being written in 待派发 of workspace `ws` done with (added, or put away): the next one's key.
pub fn board_writing_renew(ws : String) -> String {
  let id = board_next_id()
  board_writing_here[ws] = id
  id
}

///|
/// Whether something is written in 待派发's line of workspace `ws`: words or pictures, not yet added.
pub fn board_writing_kept(src : Source, ws : String) -> Bool {
  guard board_writing_here.get(ws) is Some(id) else { return false }
  @signals.untracked(fn() {
    let w = writing(src, board_file_key(ws, id))
    w.field.composed_said().trim(chars=" \n\r\t").to_owned() != "" || !w.files.get().is_empty()
  })
}

///|
/// The task's composer, kept separately in the workspace's draft store; `id` stays with its board card.
pub fn board_file_key(ws : String, id : String) -> String {
  "new:" + ws + ":board:" + id
}

///|
/// A line written down in 待派发 of workspace `ws`, to run on `station`: its key, None where nothing was written.
pub fn board_draft_add(
  src : Source,
  ws : String,
  title : String,
  station : String,
  station_name : String,
  id? : String = "",
  files? : Array[BoardFile] = [],
) -> String? {
  let words = title.trim(chars=" \n\r\t").to_owned()
  guard (words != "" || !files.is_empty()) && station != "" else { return None }
  let id = if id == "" { board_next_id() } else { id }
  // (newest first, as the board's chats are: where it was written, at 待派发's top)
  let was = @signals.untracked(fn() { board_drafts_kept(src, ws) })
  board_drafts_put(src, ws, [{ id, title: words, station, station_name, files }] + was)
  Some(id)
}

///|
/// Draft `id` changed in place (its panel's): its words and the station it goes to (`station`, named `station_name`),
/// keeping its key, order and files. Words left empty keep the words it had where it carries no file.
pub fn board_draft_set(src : Source, ws : String, id : String, title : String, station : String, station_name : String) -> Unit {
  let words = title.trim(chars=" \n\r\t").to_owned()
  let was = @signals.untracked(fn() { board_drafts_kept(src, ws) })
  guard was.iter().find_first(fn(d) { d.id == id }) is Some(d) else { return }
  let title = if words == "" && d.files.is_empty() { d.title } else { words }
  let station_name = if station == "" { d.station_name } else { station_name }
  let station = if station == "" { d.station } else { station }
  guard d.title != title || d.station != station || d.station_name != station_name else { return }
  board_drafts_put(src, ws, was.map(fn(x : BoardDraft) { if x.id == id { { ..x, title, station, station_name } } else { x } }))
}

///|
/// Draft `id` of workspace `ws` let go of (deleted, or its chat made).
pub fn board_draft_remove(src : Source, ws : String, id : String, discard_files? : Bool = true) -> Unit {
  let was = @signals.untracked(fn() { board_drafts_kept(src, ws) })
  guard was.iter().any(fn(d) { d.id == id }) else { return }
  if discard_files {
    for d in was {
      if d.id == id {
        board_files_discard(src, ws, id, d.files)
        board_pick_forget(src, d.station, id)
      }
    }
  }
  board_drafts_put(src, ws, was.filter(fn(d) { d.id != id }))
}

///|
/// A discarded task's files are released by the same composer that kept them.
pub fn board_files_discard(src : Source, ws : String, id : String, files : Array[BoardFile]) -> Unit {
  if files.is_empty() { return }
  let w = writing(src, board_file_key(ws, id))
  for f in files {
    writing_remove(src, w, f.id)
  }
}

///|
/// The key draft `d`'s chat is made under: its own (`new:…`), as the core's pending chats are.
pub fn board_key_of(d : BoardDraft) -> String {
  if d.id.has_prefix("new:") {
    d.id
  } else {
    "new:" + d.id
  }
}

///|
/// Draft `d` of workspace `ws` started: its card its chat's at once (board_items), the chat made under its key and
/// then its words sent into it, as a new chat's page sends; made, the draft let go of (the core keeps the chat as it
/// is being made); not made, the draft back in 待派发 and why said.
pub fn board_start(src : Source, ws : String, d : BoardDraft) -> Unit {
  guard !board_started.untracked().iter().any(fn(s) { s.draft.id == d.id }) else { return }
  if src.read_only {
    toast_later(read_only_words)
    return
  }
  let key = board_key_of(d)
  let name = d.station + "/" + key
  board_titles_here[name] = d.title
  board_started.set(board_started.untracked() + [{ ws, draft: d, key }])
  let w = if d.files.is_empty() { None } else { Some(writing(src, board_file_key(ws, d.id))) }
  let failed = fn(why : String) {
    board_titles_here.remove(name)
    board_seen_here.remove(name)
    board_started.set(board_started.untracked().filter(fn(s) { s.draft.id != d.id }))
    toast_later(why)
  }
  let create = fn(taken : Json?) {
    // (with what was picked for it: its own control's, as a new chat there runs where nothing was)
    let made : Map[String, Json] = { "station": Json::string(d.station), "key": Json::string(key), "of": Json::string(board_pick_of(d.id)) }
    (src.call)("newChat.create", Json::object(made), fn(res) {
      match res {
        Ok(_) => {
          board_draft_remove(src, ws, d.id, discard_files=false)
          let p : Map[String, Json] = {
            "station": Json::string(d.station),
            "session": Json::string(key),
            "text": Json::string(d.title),
            "attachments": Json::array(items(taken, "attachments")),
            "quotes": Json::array(items(taken, "quotes")),
          }
          let uploads = items(taken, "uploads")
          if !uploads.is_empty() { p["uploads"] = Json::array(uploads) }
          (src.call)("chat.send", Json::object(p), fn(sent) {
            match sent {
              Err(e) => {
                let why = text(Some(e), "message")
                // Refused before the outbox took it: put the files and words back in the created chat's composer.
                if ["invalid_params", "core_restarted", "closed"].contains(text(Some(e), "code")) {
                  match w {
                    Some(w) => {
                      let chat_draft = d.station + ":" + key
                      writing_carry(src, w.key, chat_draft)
                      writing_back_or_said(src, writing(src, chat_draft), why)
                    }
                    None => ()
                  }
                } else {
                  // (in the outbox, which sends it: never put back, its files' bytes let go of as one taken)
                  match w {
                    Some(w) => writing_committed(w)
                    None => ()
                  }
                }
                toast_later(why)
              }
              // (gone for good: what it took of the draft, its files' bytes, let go of)
              Ok(_) =>
                match w {
                  Some(w) => writing_committed(w)
                  None => ()
                }
            }
          })
        }
        Err(e) => {
          let why = text(Some(e), "message")
          match w {
            Some(w) => writing_restore(src, w, why)
            None => ()
          }
          failed(why)
        }
      }
    })
  }
  match w {
    None => create(None)
    Some(w) => {
      writing_text(src, w, d.title)
      writing_take(src, w, station=d.station, fn(taken) {
        match taken {
          Some(t) if items(Some(t), "attachments").length() + items(Some(t), "uploads").length() == d.files.length() => create(Some(t))
          _ => {
            writing_restore(src, w, "")
            failed(@sf.t("web-main.board.files_unavailable"))
          }
        }
      })
    }
  }
}

///|
/// What the shell does as the list is shown again in place of the board (sfdesk's: the tape's sidebar brought over).
// kept across runs: put in place again by each frame that shows the board (sfdesk's board_listed_back)
pub let board_listed : Ref[() -> Unit] = Ref(fn() {  })

///|
/// The board shown or the list in the workspace in view: what is open beside it closed; what is being written in
/// 待派发 kept, open again as the board is shown.
pub fn board_set(src : Source, on : Bool) -> Unit {
  guard @signals.untracked(fn() { workspace_in_view(src).0 }) is Some(w) else { return }
  board_pick.set(None)
  // (open again on what was being written in 待派发 and left for a chat or the list: its words kept, not put away)
  board_adding.set(on && board_writing_kept(src, w.id))
  // (the board narrows to all or mine alone: shown as watching, its 监控中 column; hidden, all of them)
  if on {
    match filter_of(src, w.id) {
      "watching" => {
        board_lane.set("watch")
        set_filter_of(src, w.id, "all")
      }
      "hidden" => set_filter_of(src, w.id, "all")
      _ => ()
    }
  }
  set_board_on(src, w.id, on)
  // (the list again: what the shell does besides, the tape's sidebar brought over)
  if !on {
    (board_listed.val)()
  }
  // (the board is Home's: the stack back to it)
  if on {
    if app.nav.pages()[0] == Home {
      // (Home kept where it is: what was over it taken off)
      if app.nav.depth() > 1 {
        history_act(fn() { nav_home() })
      }
    } else {
      go_place("chats", kept=true) |> ignore
    }
  }
}

///|
/// What the board of workspace `ws` is narrowed to: `mine` where its list is, else `all` (its 监控中 a column of its own,
/// what is hidden the list's).
pub fn board_filter_of(src : Source, ws : String) -> String {
  if filter_of(src, ws) == "mine" {
    "mine"
  } else {
    "all"
  }
}

///|
/// Whether the board shows chat `i` as a card of its own: not one an agent leads (chat_create for me), which is its
/// leader's, said under it (its card's `subchats`).
pub fn board_card_own(i : ChatItem) -> Bool {
  !i.opener_led
}

///|
/// The chats of workspace `ws` the board shows: every one listed (as board_filter_of narrows them), the newest first,
/// and a draft started whose chat the core does not list yet as that chat's card (under the key it is made under: the
/// same card as its pending row and the station's row after it).
pub fn board_items(src : Source, ws : String) -> Array[ChatItem] {
  let all : Array[ChatItem] = []
  match chats_of_query(src, ws, board_list_query(src, ws)).0 {
    Some(v) =>
      for d in v.days {
        for i in d.items {
          if board_card_own(i) {
            all.push(i)
          }
        }
      }
    None => ()
  }
  // When filtering by a specific named project, cross-project, or tag, local drafts (which have no project/tags) do not match.
  let hide_drafts = projects_cap(src, ws) == On &&
    (project_filter_of(ws) is Named(_) || tag_filter_of(ws) is Some(_))
  // (stood in for till the core lists it: from then on the core's alone, gone with it as it goes)
  let coming : Array[ChatItem] = []
  if !hide_drafts {
    for s in board_started.get() {
      let name = s.draft.station + "/" + s.key
      guard s.ws == ws && !board_seen_here.contains(name) else { continue }
      let mut listed = false
      for i in all {
        if row_name(i) == name {
          listed = true
          break
        }
      }
      if listed {
        board_seen_here[name] = true
      } else {
        coming.push(board_coming(s))
      }
    }
  }
  coming + all
}

///|
/// The card of draft started `s` while the core lists no chat of it: at work on its station, its words its title.
fn board_coming(s : BoardStarted) -> ChatItem {
  let starting = @sf.t("web-main.board.starting")
  chat_item({
    "id": Json::string(s.key),
    "session": Json::string(s.key),
    "clientKey": Json::string(s.key),
    "station": Json::string(s.draft.station),
    "stationName": Json::string(s.draft.station_name),
    "title": Json::string(s.draft.title),
    "state": "run",
    "stage": "run",
    "pending": true,
    "stateLead": "wait",
    "stateText": Json::string(starting),
    "stateRest": Json::string(starting),
  })
}

///|
/// What a card of chat `item` is titled: its own, but while its chat is being made (the core's pending row, titled 新对话
/// till its station names it) the words it was started with.
pub fn board_title_of(item : ChatItem) -> String {
  if item.pending && item.title == @sf.t("core-views.new_chat") {
    match board_titles_here.get(row_name(item)) {
      Some(t) => t
      None =>
        match item.last {
          Some(l) if l != "" => l
          _ => item.title
        }
    }
  } else {
    item.title
  }
}

///|
/// What the board of workspace `ws` reads as it is first shown, where it is shown (its chats as board_filter_of narrows
/// them, and its stations' rows): all of it answered. True at once where the workspace shows its list.
pub fn board_opens(src : Source, ws : String, ask : (String, Map[String, Json]) -> TopicState) -> Bool {
  guard board_on_of(src, ws) else { return true }
  let (name, params) = station_rows_ask(ws)
  let chats = opens_answered(ask("chats", chats_params_query(ws, board_list_query(src, ws))))
  let stations = opens_answered(ask(name, params))
  chats && stations
}

///|
/// The viewer as the board names them among the people of `items`: their name and （我）, else 我.
pub fn board_me_of(items : Array[ChatItem]) -> String {
  for i in items {
    for p in i.people {
      if p.mine && p.name != "" {
        return @sf.t("web-main.board.me_named", args=[("name", p.name)])
      }
    }
  }
  @sf.t("web-main.board.me")
}

///|
/// Who chat `i` is of, as the board groups it by person (`me` the viewer as it names them): those in it, else the
/// viewer.
pub fn board_people_of(i : ChatItem, me : String) -> Array[String] {
  let names : Array[String] = []
  for p in i.people {
    let n = if p.mine { me } else { p.name }
    if n != "" && !names.contains(n) {
      names.push(n)
    }
  }
  if names.is_empty() {
    names.push(me)
  }
  names
}

///|
/// How wide the chat beside a wide board is to be: as its edge was dragged here, else as the prefs keep it (`sidebars`'
/// board_chat_key), else board_chat_w_default; the board's room beside it may leave less (sfpages' board_wide).
pub fn board_chat_w_of(src : Source) -> Double {
  match board_chat_w_here.get() {
    Some(w) => if w <= 0.0 { board_chat_w_default } else { w }
    None =>
      match field(field(src.topic("prefs", {}).get().value, "sidebars"), board_chat_key) {
        Some(String(s)) =>
          match board_whole_of(s) {
            Some(n) if n > 0 => n.to_double()
            _ => board_chat_w_default
          }
        _ => board_chat_w_default
      }
  }
}

///|
/// The chat beside a wide board made `w` wide by its edge (None: its own width again); `save`, kept in the prefs too
/// (`sidebars`, a width there whole points in words: core-ts prefs.ts), else shown so alone while the edge is in hand.
pub fn set_board_chat_w(src : Source, w : Double?, save~ : Bool) -> Unit {
  match w {
    Some(x) => {
      let n = x.round()
      board_chat_w_here.set(Some(n))
      if save {
        (src.call)(
          "prefs.set",
          { "sidebars": Json::object(Map::from_array([(board_chat_key, Json::string(n.to_int().to_string()))])) },
          answer_unread,
        )
      }
    }
    None => {
      board_chat_w_here.set(Some(0.0))
      if save {
        (src.call)("prefs.set", { "sidebars": Json::object(Map::from_array([(board_chat_key, Json::null())])) }, answer_unread)
      }
    }
  }
}

///|
/// A whole number written in decimal digits alone, four at most as the prefs' `sidebars` keep one ("" or anything
/// else: None).
fn board_whole_of(s : String) -> Int? {
  guard s.length() > 0 && s.length() <= 4 else { return None }
  let mut n = 0
  for c in s {
    guard c >= '0' && c <= '9' else { return None }
    n = n * 10 + (c.to_int() - '0'.to_int())
  }
  Some(n)
}
