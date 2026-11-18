// A 待派发 draft clarified before it is dispatched (先理清, its card's menu: sfpages board_node.mbt draft_clarify_card):
// the agent is asked to turn its words into tasks (`board.clarify`), each a short title and its brief (目标, 范围,
// 验收标准, 需要确认的问题); they show in the draft's card's place to be edited, one deleted or one added by hand, and
// leave as 待派发 cards of one group (放入待派发) or each its own chat (全部派发, or one at a time). What the board keeps of
// it while it is open; the board draws it.
//
// A preview: the core has no `board.clarify` yet, and only the made-up core answers it (sffixture newchat_fixture.mbt,
// with tasks of its own after a beat). The core's will take the draft's words and its station and answer
// `{tasks: [{title, goal, scope, accept, ask}]}`, each part plain text (client/core-ts/src/shapes/schema.ts beside
// BoardDraft, with its call among the board's); this app reads only that, here. Merging two tasks is not offered yet.

///|
/// Where the draft being clarified stands: its words with the agent, the tasks to come; the tasks come, to be edited.
#derive(Eq)
pub(all) enum ClarifyStep {
  Organizing
  Ready
}

///|
/// One task of the split, each part a field of its own as it is edited; `id` its own while the split is open (the
/// node made for it stays its own as others are added or deleted).
pub(all) struct ClarifyTask {
  id : Int
  title : @ui.Field
  goal : @ui.Field
  scope : @ui.Field
  accept : @ui.Field
  ask : @ui.Field
}

///|
/// A task is the same task by its id (its fields are its own, edited in place).
pub impl Eq for ClarifyTask with equal(self, other) {
  self.id == other.id
}

///|
/// What the board keeps of it: the draft clarified (its id, "" none open), where it stands, the words it was asked of,
/// the tasks as they are edited.
pub(all) struct Clarify {
  draft : @signals.Signal[String]
  step : @signals.Signal[ClarifyStep]
  words : @signals.Signal[String]
  tasks : @signals.Signal[Array[ClarifyTask]]
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
  asked: 0,
  made: 0,
}

///|
/// No draft being clarified: what was open let go, an answer still to come touching nothing.
pub fn clarify_reset() -> Unit {
  clarify.asked += 1
  @signals.start_batch()
  clarify.draft.set("")
  clarify.step.set(Organizing)
  clarify.words.set("")
  clarify.tasks.set([])
  @signals.end_batch()
}

///|
/// A task of parts `t` (`{title, goal, scope, accept, ask}`, each "" where it says none), its fields holding them.
pub fn clarify_task_of(t : Json) -> ClarifyTask {
  clarify.made += 1
  let o = Some(t)
  {
    id: clarify.made,
    title: @ui.Field::new(text=text(o, "title")),
    goal: @ui.Field::new(text=text(o, "goal")),
    scope: @ui.Field::new(text=text(o, "scope")),
    accept: @ui.Field::new(text=text(o, "accept")),
    ask: @ui.Field::new(text=text(o, "ask")),
  }
}

///|
/// The tasks the core answered (`{tasks: [...]}`), each into fields: the split shown to be edited.
pub fn clarify_fill(answer : Json) -> Unit {
  clarify.tasks.set(items(Some(answer), "tasks").map(clarify_task_of))
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
  clarify.tasks.set(clarify.tasks.untracked() + [clarify_task_of(Json::object({}))])
}

///|
/// Task `id` taken out of the split.
pub fn clarify_remove(id : Int) -> Unit {
  clarify.tasks.set(clarify.tasks.untracked().filter(fn(t) { t.id != id }))
}

///|
/// Task `t` as a 待派发 draft's words, plain text: its title, then each part that says something under its name
/// (目标：…), a blank line between parts ("" where it says nothing at all). The first part is on the line right after
/// the title: a card shows two lines of a draft, so its second is the 目标, not a blank line cut to "…".
pub fn clarify_task_text(t : ClarifyTask) -> String {
  let parts = [
    ("web-main.board.clarify.goal", t.goal),
    ("web-main.board.clarify.scope", t.scope),
    ("web-main.board.clarify.accept", t.accept),
    ("web-main.board.clarify.ask", t.ask),
  ]
  let out : Array[String] = []
  let title = t.title.text().trim(chars=" \n\t").to_owned()
  for part in parts {
    let (key, f) = part
    let words = f.text().trim(chars=" \n\t").to_owned()
    if words == "" {
      continue
    }
    // (a part of several lines starts on the line after its name)
    let sep = if words.contains("\n") { "\n" } else { "" }
    out.push(@sf.t(key) + "：" + sep + words)
  }
  let body = out.join("\n\n")
  match (title, body) {
    ("", _) => body
    (_, "") => title
    _ => title + "\n" + body
  }
}

///|
/// The split's tasks as their words (clarify_task_text), those that say something.
pub fn clarify_texts() -> Array[String] {
  clarify.tasks.untracked().map(clarify_task_text).filter(fn(w) { w != "" })
}
