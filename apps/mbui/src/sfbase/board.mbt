// The chats as a board (看板), a way of showing Home's chats beside the list (列表): the workspace's chats in columns
// by where each stands (待派发, 等你处理, 进行中, 待收口, 监控中), by the station it runs on, or by who is in it. What a
// chat stands at is the core's (its row's state, tone, lead): the board only sorts by it, so a card goes to another
// column only as its chat goes on. Whether a workspace shows its board, how it is grouped and the drafts of its 待派发
// are this device's, kept in the core's prefs (`boardViews`, `boardGroups`, `boardShowEmpty`, `boardDrafts`) by workspace, what was
// chosen here shown at once while the core takes it. A draft started becomes a chat as a new chat's page makes one
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
/// Whether a card is in the hand (dragged).
pub let board_drag_active : @signals.Signal[Bool] = @signals.signal(false)

///|
/// A line written down to start later (待派发): its key (`new:board-…`, the key its chat is made under), its words, the
/// station it is to run on and that station's name.
#derive(Eq, Debug)
pub(all) struct BoardDraft {
  id : String
  title : String
  station : String
  station_name : String
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
/// Each workspace's drafts as written here, by workspace (board_views_here's).
// kept across runs: put back by board_reset as a run starts
let board_drafts_here : Map[String, Array[BoardDraft]] = Map([])

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
/// As at the start: nothing chosen here, nothing open, in hand or started.
pub fn board_reset() -> Unit {
  board_views_here.clear()
  board_groups_here.clear()
  board_empty_here.clear()
  board_drafts_here.clear()
  board_titles_here.clear()
  board_seen_here.clear()
  board_written.val = 0
  board_rev.set(0)
  board_started.set([])
  board_transient_reset()
}

///|
/// What is open on the board, in hand or being written put away (another workspace come in view).
pub fn board_transient_reset() -> Unit {
  board_pick.set(None)
  board_adding.set(false)
  board_lane.set("wait")
  board_drag_active.set(false)
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
/// Where chat `i` stands on the board, as its row says (the core's): a message of the viewer's that did not go, or the
/// chat waiting on them (a decision, help asked, failed); keeping watch; at work (running, waiting on what it set off,
/// being made, no agent in it yet); else done and not yet put away.
pub fn board_lane_of(i : ChatItem) -> String {
  if i.unsent {
    "wait"
  } else if i.state_lead == "watch" {
    "watch"
  } else if i.state == "block" ||
    i.state == "failed" ||
    i.state_lead == "decision" ||
    i.state_lead == "need" ||
    i.decision_text is Some(_) {
    "wait"
  } else if i.state == "run" || i.state_lead == "wait" || i.pending || i.agents.is_empty() {
    "run"
  } else {
    "done"
  }
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
/// The drafts of workspace `ws` as kept (newest first), started ones too.
fn board_drafts_kept(src : Source, ws : String) -> Array[BoardDraft] {
  board_rev.get() |> ignore
  match board_drafts_here.get(ws) {
    Some(d) => d
    None =>
      match board_kept(src, "boardDrafts", ws) {
        Some(Array(a)) =>
          a
          .map(fn(d) -> BoardDraft {
            let one = Some(d)
            {
              id: text(one, "id"),
              title: text(one, "title"),
              station: text(one, "station"),
              station_name: text(one, "stationName"),
            }
          })
          .filter(fn(d) { d.id != "" && d.title != "" })
        _ => []
      }
  }
}

///|
/// Workspace `ws`'s drafts made `drafts` (newest first): shown so at once, kept so in the prefs.
fn board_drafts_put(src : Source, ws : String, drafts : Array[BoardDraft]) -> Unit {
  board_drafts_here[ws] = drafts
  board_rev.set(board_rev.untracked() + 1)
  let kept = Json::array(
    drafts.map(fn(d) {
      Json::object({
        "id": Json::string(d.id),
        "title": Json::string(d.title),
        "station": Json::string(d.station),
        "stationName": Json::string(d.station_name),
      })
    }),
  )
  (src.call)("prefs.set", { "boardDrafts": board_of_ws(ws, kept) }, answer_unread)
}

///|
/// 待派发 of workspace `ws` as it shows: its drafts not started.
pub fn board_drafts_of(src : Source, ws : String) -> Array[BoardDraft] {
  let started = board_started.get()
  board_drafts_kept(src, ws).filter(fn(d) { !started.iter().any(fn(s) { s.draft.id == d.id }) })
}

///|
/// A line written down in 待派发 of workspace `ws`, to run on `station`: its key, None where nothing was written.
pub fn board_draft_add(
  src : Source,
  ws : String,
  title : String,
  station : String,
  station_name : String,
) -> String? {
  let words = title.trim(chars=" \n\r\t").to_owned()
  guard words != "" && station != "" else { return None }
  board_written.val += 1
  let id = "new:board-\{@hostapi.wall_ms().to_int64()}-\{board_written.val}"
  // (newest first, as the board's chats are: where it was written, at 待派发's top)
  let was = @signals.untracked(fn() { board_drafts_kept(src, ws) })
  board_drafts_put(src, ws, [{ id, title: words, station, station_name }] + was)
  Some(id)
}

///|
/// Draft `id` of workspace `ws` let go of (deleted, or its chat made).
pub fn board_draft_remove(src : Source, ws : String, id : String) -> Unit {
  let was = @signals.untracked(fn() { board_drafts_kept(src, ws) })
  guard was.iter().any(fn(d) { d.id == id }) else { return }
  board_drafts_put(src, ws, was.filter(fn(d) { d.id != id }))
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
  (src.call)("newChat.create", { "station": Json::string(d.station), "key": Json::string(key) }, fn(res) {
    match res {
      Ok(_) => {
        board_draft_remove(src, ws, d.id)
        (src.call)(
          "chat.send",
          {
            "station": Json::string(d.station),
            "session": Json::string(key),
            "text": Json::string(d.title),
            "attachments": Json::array([]),
            "quotes": Json::array([]),
          },
          fn(sent) {
            match sent {
              Err(e) => toast_later(text(Some(e), "message"))
              Ok(_) => ()
            }
          },
        )
      }
      Err(e) => {
        board_titles_here.remove(name)
        board_seen_here.remove(name)
        board_started.set(board_started.untracked().filter(fn(s) { s.draft.id != d.id }))
        toast_later(text(Some(e), "message"))
      }
    }
  })
}

///|
/// What the shell does as the list is shown again in place of the board (sfdesk's: the tape's sidebar brought over).
// kept across runs: put in place again by each frame that shows the board (sfdesk's board_listed_back)
pub let board_listed : Ref[() -> Unit] = Ref(fn() {  })

///|
/// The board shown or the list in the workspace in view: what is open beside it closed, what is being written put
/// away.
pub fn board_set(src : Source, on : Bool) -> Unit {
  guard @signals.untracked(fn() { workspace_in_view(src).0 }) is Some(w) else { return }
  board_pick.set(None)
  board_adding.set(false)
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
      go_place("chats") |> ignore
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
/// The chats of workspace `ws` the board shows: every one listed (as board_filter_of narrows them), the newest first,
/// and a draft started whose chat the core does not list yet as that chat's card (under the key it is made under: the
/// same card as its pending row and the station's row after it).
pub fn board_items(src : Source, ws : String) -> Array[ChatItem] {
  let all : Array[ChatItem] = []
  match chats_of(src, ws, board_filter_of(src, ws)).0 {
    Some(v) =>
      for d in v.days {
        for i in d.items {
          all.push(i)
        }
      }
    None => ()
  }
  // (stood in for till the core lists it: from then on the core's alone, gone with it as it goes)
  let coming : Array[ChatItem] = []
  for s in board_started.get() {
    let name = s.draft.station + "/" + s.key
    guard s.ws == ws && !board_seen_here.contains(name) else { continue }
    if all.iter().any(fn(i) { row_name(i) == name }) {
      board_seen_here[name] = true
    } else {
      coming.push(board_coming(s))
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
  let chats = opens_answered(ask("chats", chats_params(ws, board_filter_of(src, ws))))
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
