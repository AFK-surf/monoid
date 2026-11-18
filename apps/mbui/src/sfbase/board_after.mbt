// What a 待派发 draft waits for (先理清's 「等 X」: its `after`, sfbase's board.mbt BoardDraft), and its starting itself
// once all of it is done (board_after_due, by the board as it shows: sfpages' board_node).
//
// The rules, each predecessor by its key (a draft's key is the key its chat is made under and keeps, board_key_of):
// - still a draft (in 待派发, or started and not yet listed): waited for, by its words;
// - its chat listed: 待收口 (board_lane_of `done`) is done with, remembered so for the run (archived after, it stays
//   done); errored (its row's state `failed`) is 「X 出错了」; else waited for;
// - neither, with the chats listed: gone (its draft deleted, or its chat archived or deleted before 待收口), 「等的 X 已
//   删除」. Before the chats are listed nothing is gone: waited for.
// Gone or errored, it never starts by itself: its card offers 立即派发 and 去掉这个依赖 (board_after_drop: what is gone
// or errored let go of, what is left waited for as before). All done, it is started by board_start, the path any card
// takes, once: marked as starting here before it is started (board_after_tried), so a second change while it starts
// finds it marked; a start that failed is marked with why (BoardWait::Unstarted), shown on its card, and not tried
// again this run: 立即派发 tries it again. What is waited for is this device's: the drafts are kept in its prefs alone,
// never another device's, so no other device starts it too; and only while an app shows the board of its workspace.

///|
/// Where a draft stands as to what it waits for.
#derive(Eq, Debug)
pub(all) enum BoardWait {
  /// waits for nothing
  Free
  /// waits for these, by their words, still to be done
  Waits(Array[String])
  /// waited for all of them, done: to start now
  Ready
  /// one of them gone, by its words
  Gone(String)
  /// one of them errored, by its words
  Failed(String)
  /// its start, by itself, failed: why
  Unstarted(String)
}

///|
/// A predecessor of a draft, as it stands.
priv enum AfterNow {
  AfterWaits(String)
  AfterDone
  AfterGone(String)
  AfterFailed(String)
}

///|
/// The predecessors done with in this run (in 待收口 once), by their keys: done for good though archived since.
// kept across runs: put back by board_after_reset (board_reset)
let board_after_done : Map[String, Bool] = Map([])

///|
/// The drafts started by themselves in this run, by their keys: "" being started, else why their start failed.
// kept across runs: put back by board_after_reset (board_reset)
let board_after_tried : Map[String, String] = Map([])

///|
/// As at the start: nothing done with, nothing started by itself.
pub fn board_after_reset() -> Unit {
  board_after_done.clear()
  board_after_tried.clear()
}

///|
/// Words cut to `n` characters at most, … where cut.
pub fn board_after_short(words : String, n? : Int = 12) -> String {
  let line = match words.split("\n").next() {
    Some(l) => l.to_owned()
    None => words
  }
  let chars = line.to_array()
  if chars.length() <= n {
    line
  } else {
    String::from_array(chars[:n]) + "…"
  }
}

///|
/// Predecessor `a` as it stands among `drafts` (those not started) and the chats `items` (`listed`: the core lists them).
fn board_after_now(a : BoardAfter, drafts : Array[BoardDraft], items : Array[ChatItem], listed : Bool) -> AfterNow {
  if drafts.search_by(fn(d) { d.id == a.id }) is Some(at) {
    return AfterWaits(drafts[at].title)
  }
  let key = if a.id.has_prefix("new:") { a.id } else { "new:" + a.id }
  match items.search_by(fn(i) { i.client_key == key || i.id == key }) {
    Some(at) => {
      let i = items[at]
      if i.state == "failed" {
        AfterFailed(a.title)
      } else if board_lane_of(i) == "done" {
        board_after_done[a.id] = true
        AfterDone
      } else {
        AfterWaits(a.title)
      }
    }
    None if board_after_done.contains(a.id) => AfterDone
    None if !listed => AfterWaits(a.title)
    None => AfterGone(a.title)
  }
}

///|
/// Where draft `d` stands as to what it waits for, among `drafts` (待派发's, not started), the chats `items` the board
/// shows (`listed`: the core lists them; before, nothing is gone). What errored comes before what is gone, and either
/// before what is still waited for.
pub fn board_wait_of(d : BoardDraft, drafts : Array[BoardDraft], items : Array[ChatItem], listed : Bool) -> BoardWait {
  match board_after_tried.get(d.id) {
    Some(why) if why != "" => return Unstarted(why)
    _ => ()
  }
  guard !d.after.is_empty() else { return Free }
  let waits : Array[String] = []
  let mut gone : String? = None
  let mut failed : String? = None
  for a in d.after {
    match board_after_now(a, drafts, items, listed) {
      AfterWaits(t) => waits.push(t)
      AfterDone => ()
      AfterGone(t) => if gone is None { gone = Some(t) }
      AfterFailed(t) => if failed is None { failed = Some(t) }
    }
  }
  match (failed, gone) {
    (Some(t), _) => Failed(t)
    (_, Some(t)) => Gone(t)
    _ if !waits.is_empty() => Waits(waits)
    _ => Ready
  }
}

///|
/// Of `drafts` (待派发's, not started), those whose predecessors are all done and not yet started by themselves: to
/// start now (board_after_start).
pub fn board_after_due(drafts : Array[BoardDraft], items : Array[ChatItem], listed : Bool) -> Array[BoardDraft] {
  drafts.filter(fn(d) { !board_after_tried.contains(d.id) && board_wait_of(d, drafts, items, listed) == Ready })
}

///|
/// Draft `d` of workspace `ws`, all it waited for done, started by itself (board_start): marked first, so it is started
/// once; failed, marked with why and its card back in 待派发 saying so.
pub fn board_after_start(src : Source, ws : String, d : BoardDraft) -> Unit {
  guard !board_after_tried.contains(d.id) else { return }
  board_after_tried[d.id] = ""
  board_start(src, ws, d, failed=fn(why) {
    board_after_tried[d.id] = if why == "" { @sf.t("web-main.board.clarify.auto_failed_unknown") } else { why }
    board_rev.set(board_rev.untracked() + 1)
  })
}

///|
/// Draft `id` of workspace `ws` started now by a person (立即派发 on a card that waits): what it waited for and its failed
/// start by itself let go of, started as any card is.
pub fn board_after_now_start(src : Source, ws : String, d : BoardDraft) -> Unit {
  board_after_tried.remove(d.id)
  board_start(src, ws, d)
}

///|
/// Of draft `id` of workspace `ws`, what it waits for that is gone or errored let go of (去掉这个依赖): what is left
/// still waited for; nothing left, it is a draft as any other, or started by itself where all of it is done.
pub fn board_after_drop(src : Source, ws : String, id : String, items : Array[ChatItem], listed : Bool) -> Unit {
  let was = @signals.untracked(fn() { board_drafts_kept(src, ws) })
  let open = board_drafts_of(src, ws)
  board_after_tried.remove(id)
  board_drafts_put(src, ws, was.map(fn(d) {
    if d.id != id {
      d
    } else {
      { ..d, after: d.after.filter(fn(a) { board_after_now(a, open, items, listed) is (AfterWaits(_) | AfterDone) }) }
    }
  }))
}

///|
/// What a waiting draft's card says of it (「等 X」, 「等的 X 已删除」, 「X 出错了」, the start that failed), "" none.
pub fn board_wait_words(w : BoardWait) -> String {
  match w {
    Free | Ready => ""
    Waits(ts) => {
      let first = board_after_short(ts[0])
      if ts.length() == 1 {
        @sf.t("web-main.board.clarify.waits", args=[("task", first)])
      } else {
        @sf.t("web-main.board.clarify.waits_more", args=[("task", first), ("n", (ts.length() - 1).to_string())])
      }
    }
    Gone(t) => @sf.t("web-main.board.clarify.wait_gone", args=[("task", board_after_short(t, n=8))])
    Failed(t) => @sf.t("web-main.board.clarify.wait_failed", args=[("task", board_after_short(t, n=8))])
    Unstarted(why) => @sf.t("web-main.board.clarify.auto_failed", args=[("error", why)])
  }
}

///|
/// Whether the core lists the chats of workspace `ws` as its board shows them (before it does, no predecessor is gone).
pub fn board_listed_of(src : Source, ws : String) -> Bool {
  chats_of(src, ws, board_filter_of(src, ws)).0 is Some(_)
}
