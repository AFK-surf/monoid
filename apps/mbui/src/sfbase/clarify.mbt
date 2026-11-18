// A 待派发 draft clarified before it is dispatched (先理清, its card's menu: sfpages board_node.mbt draft_clarify_card):
// its station's agent is asked to turn its words into subtasks (`board.clarify`, the core's op: the station's one-off
// session with no tools, station/src/sessions/clarify-tasks.ts), each one line of what to do, and which earlier ones it
// waits for; they show in the draft's card's place, each line to edit, delete, start alone or mark 「等 X」, a line added
// by hand, and leave as 待派发 cards of one group (放入待派发) or as chats (全部派发: those that wait for none; the others
// wait in 待派发 and start themselves, sfbase's board_after.mbt). What the board keeps of it while it is open; the board
// draws it. The core answers `{tasks: [{text, after?}]}` (`after`: 0-based places of earlier tasks).

///|
/// Where the draft being clarified stands: its words with the agent, the tasks to come; the tasks come, to be edited.
#derive(Eq)
pub(all) enum ClarifyStep {
  Organizing
  Ready
}

///|
/// One task of the split: its line, being edited, and the tasks of the split it waits for (by their ids); `id` its own
/// while the split is open (the node made for it stays its own as others are added or deleted).
pub(all) struct ClarifyTask {
  id : Int
  text : @ui.Field
  after : @signals.Signal[Array[Int]]
}

///|
/// A task is the same task by its id (its fields are its own, edited in place).
pub impl Eq for ClarifyTask with equal(self, other) {
  self.id == other.id
}

///|
/// What the board keeps of it: the draft clarified (its id, "" none open), where it stands, the words it was asked of,
/// the tasks as they are edited, and the tasks started alone from it, each by its id the draft it became (what waits for
/// one waits for that draft).
pub(all) struct Clarify {
  draft : @signals.Signal[String]
  step : @signals.Signal[ClarifyStep]
  words : @signals.Signal[String]
  tasks : @signals.Signal[Array[ClarifyTask]]
  started : Map[Int, BoardAfter]
  /// counts the asks: an answer to one asked before the split was closed touches nothing
  mut asked : Int
  /// counts the tasks made, each its id
  mut made : Int
}

///|
// kept across runs: put back by clarify_reset (closed, and the app's reset)
pub let clarify : Clarify = {
  draft: @signals.signal("", same=fn(a, b) { a == b }),
  step: @signals.signal(Organizing, same=fn(a, b) { a == b }),
  words: @signals.signal("", same=fn(a, b) { a == b }),
  tasks: @signals.signal([]),
  started: Map([]),
  asked: 0,
  made: 0,
}

///|
/// No draft being clarified: what was open let go, an answer still to come touching nothing.
pub fn clarify_reset() -> Unit {
  clarify.asked += 1
  clarify.started.clear()
  @signals.start_batch()
  clarify.draft.set("")
  clarify.step.set(Organizing)
  clarify.words.set("")
  clarify.tasks.set([])
  @signals.end_batch()
}

///|
/// A task of words `words`, waiting for the tasks of ids `after`.
pub fn clarify_task_of(words : String, after? : Array[Int] = []) -> ClarifyTask {
  clarify.made += 1
  { id: clarify.made, text: @ui.Field::new(text=words), after: @signals.signal(after) }
}

///|
/// The tasks the core answered (`{tasks: [{text, after?}]}`), each a line: the split shown to be edited, each waiting
/// for the earlier ones its `after` names (a place that is not an earlier task's is no wait).
pub fn clarify_fill(answer : Json) -> Unit {
  let made : Array[ClarifyTask] = []
  for t in items(Some(answer), "tasks") {
    let after : Array[Int] = []
    for a in items(Some(t), "after") {
      if a is Number(n, ..) {
        let at = n.to_int()
        if at.to_double() == n && at >= 0 && at < made.length() && !after.contains(made[at].id) {
          after.push(made[at].id)
        }
      }
    }
    made.push(clarify_task_of(text(Some(t), "text"), after~))
  }
  clarify.tasks.set(made)
  clarify.step.set(Ready)
}

///|
/// Draft `draft` (its words `words`, on `station`) to be clarified: its card the split being made from now, the agent
/// asked for it (`board.clarify`); answered, the tasks to edit; not, the card as it was, saying why and what is left to
/// do (dispatch it as it is, or ask again).
pub fn clarify_start(src : Source, draft : String, station : String, words : String) -> Unit {
  if src.read_only {
    toast_later(read_only_words)
    return
  }
  clarify.asked += 1
  let asked = clarify.asked
  clarify.started.clear()
  @signals.start_batch()
  clarify.draft.set(draft)
  clarify.words.set(words)
  clarify.tasks.set([])
  clarify.step.set(Organizing)
  @signals.end_batch()
  (src.call)("board.clarify", { "station": Json::string(station), "words": Json::string(words) }, fn(res) {
    // (closed, or another asked, since: nothing of it shown)
    guard asked == clarify.asked else { return }
    match res {
      Ok(answer) => clarify_fill(answer)
      Err(e) => {
        clarify_reset()
        toast_later(@sf.t("web-main.board.clarify.failed", args=[("error", text(Some(e), "message"))]))
      }
    }
  })
}

///|
/// A task added by hand, empty, at the split's end.
pub fn clarify_add() -> Unit {
  clarify.tasks.set(clarify.tasks.untracked() + [clarify_task_of("")])
}

///|
/// Task `id` taken out of the split: what waited for it waits for it no more.
pub fn clarify_remove(id : Int) -> Unit {
  let left = clarify.tasks.untracked().filter(fn(t) { t.id != id })
  for t in left {
    let was = t.after.untracked()
    if was.contains(id) {
      t.after.set(was.filter(fn(a) { a != id }))
    }
  }
  clarify.tasks.set(left)
}

///|
/// Task `id` taken out of the split as it is started alone: what waited for it waits for the draft it became
/// (`clarify.started`).
pub fn clarify_remove_started(id : Int) -> Unit {
  clarify.tasks.set(clarify.tasks.untracked().filter(fn(t) { t.id != id }))
}

///|
/// Task `t`'s line as a draft's words (its edges trimmed; "" where it says nothing).
pub fn clarify_task_text(t : ClarifyTask) -> String {
  t.text.text().trim(chars=" \n\r\t").to_owned()
}

///|
/// The split's tasks' lines, those that say something.
pub fn clarify_texts() -> Array[String] {
  clarify.tasks.untracked().map(clarify_task_text).filter(fn(w) { w != "" })
}

///|
/// The task of id `id` in the split now.
pub fn clarify_task(id : Int) -> ClarifyTask? {
  clarify.tasks.untracked().iter().find_first(fn(t) { t.id == id })
}

///|
/// Whether task `from` waits, itself or through what it waits for, for task `to`.
pub fn clarify_reaches(from : Int, to : Int) -> Bool {
  let seen : Map[Int, Bool] = Map([])
  let todo = [from]
  while todo.pop() is Some(id) {
    guard !seen.contains(id) else { continue }
    seen[id] = true
    match clarify_task(id) {
      Some(t) =>
        for a in t.after.untracked() {
          if a == to {
            return true
          }
          todo.push(a)
        }
      None => ()
    }
  }
  false
}

///|
/// Whether task `t` may be made to wait for task `other`: another task, one that does not wait for `t` (no loop).
pub fn clarify_may_wait(t : ClarifyTask, other : Int) -> Bool {
  other != t.id && !clarify_reaches(other, t.id)
}

///|
/// Task `t` made to wait for task `other`, or no more where it did (its 「等 X」 menu).
pub fn clarify_toggle_wait(t : ClarifyTask, other : Int) -> Unit {
  let was = t.after.untracked()
  if was.contains(other) {
    t.after.set(was.filter(fn(a) { a != other }))
  } else if clarify_may_wait(t, other) {
    t.after.set(was + [other])
  }
}

///|
/// The tasks of the split that say something as drafts to be made (board_drafts_split): the first under the key of the
/// draft clarified (`first`), each other a new key, each waiting for the drafts its tasks wait for (or for what one of
/// them already became, started alone).
pub fn clarify_parts(first : String) -> Array[BoardPart] {
  let tasks = clarify.tasks.untracked().filter(fn(t) { clarify_task_text(t) != "" })
  let keys : Map[Int, BoardAfter] = Map([])
  for k, t in tasks {
    keys[t.id] = { id: if k == 0 { first } else { board_next_id() }, title: clarify_task_text(t), done: false }
  }
  tasks.map(fn(t) -> BoardPart {
    let after : Array[BoardAfter] = []
    for a in t.after.untracked() {
      match keys.get(a) {
        Some(k) => after.push(k)
        None =>
          match clarify.started.get(a) {
            Some(k) => after.push(k)
            None => ()
          }
      }
    }
    { id: keys[t.id].id, text: clarify_task_text(t), after }
  })
}

///|
/// The words of what task `t` waits for, in the split's order (its 「等 X」 marks): each task still in the split, or
/// started alone already.
pub fn clarify_waits_of(t : ClarifyTask) -> Array[(Int, String)] {
  let after = t.after.get()
  let out : Array[(Int, String)] = []
  for o in clarify.tasks.get() {
    if after.contains(o.id) {
      out.push((o.id, o.text.text()))
    }
  }
  for a in after {
    match clarify.started.get(a) {
      Some(k) => out.push((a, k.title))
      None => ()
    }
  }
  out
}

///|
/// What line `t` waits for, said under it: 等 1、2, each by its place in the split, or by its words where it was started
/// alone already ("" where it waits for none).
pub fn clarify_waits_words(t : ClarifyTask) -> String {
  let after = t.after.get()
  guard !after.is_empty() else { return "" }
  let tasks = clarify.tasks.get()
  let said : Array[String] = []
  for a in after {
    match tasks.search_by(fn(o) { o.id == a }) {
      Some(at) => said.push((at + 1).to_string())
      None =>
        match clarify.started.get(a) {
          Some(k) => said.push(board_after_short(k.title, n=8))
          None => ()
        }
    }
  }
  @sf.t("web-main.board.clarify.waits_nums", args=[("list", said.join(@sf.t("web-main.board.clarify.sep")))])
}
