// A new chat clarified before it is dispatched (先理清再派发, an opt-in of the new chat's page): with it on, the first
// words are not sent; the agent is asked to turn them into a task brief first (`newChat.clarify`), shown to be edited
// (目标, 范围, 验收标准, 需要确认的问题), and the chat starts only once it is confirmed, the brief its first message (or the
// words as they were). What the page keeps of it while it is a new chat; the page draws it (sfpages new_chat.mbt).
//
// A preview: the core has no `newChat.clarify` yet, and only the made-up core answers it (sffixture newchat_fixture.mbt,
// with a brief of its own after a beat). The core's will take the words and the station and answer the brief's four
// parts as text, `{goal, scope, accept, ask}` (client/core-ts/src/shapes/schema.ts beside NewChatView, with its call
// in newChat's calls); this app reads only those, here. Whether it is on is the page's own for now; the core's picks
// (`newChat.pick`) will keep it once it is more than a preview.

///|
/// Where a new chat being clarified stands: being written (its composer, as without it); its words with the agent,
/// the brief to come; the brief come, to be edited and confirmed.
#derive(Eq)
pub(all) enum ClarifyStep {
  Writing
  Organizing
  Ready
}

///|
/// What the page keeps of it: whether it is on, where it stands, the words it was asked of, the brief's four parts
/// as they are edited (each a field of its own), and what went wrong asking it ("" nothing).
pub(all) struct Clarify {
  on : @signals.Signal[Bool]
  step : @signals.Signal[ClarifyStep]
  words : @signals.Signal[String]
  goal : @ui.Field
  scope : @ui.Field
  accept : @ui.Field
  ask : @ui.Field
  /// counts the asks: an answer to one asked before the page went back to its words touches nothing
  mut asked : Int
}

///|
// kept across runs: put back by clarify_reset (the brief started from, and the app's reset), its switch kept: a new chat
// left while its brief is made or edited shows it again as it is come back to
pub let clarify : Clarify = {
  on: @signals.signal(false, same=fn(a, b) { a == b }),
  step: @signals.signal(Writing, same=fn(a, b) { a == b }),
  words: @signals.signal("", same=fn(a, b) { a == b }),
  goal: @ui.Field::new(),
  scope: @ui.Field::new(),
  accept: @ui.Field::new(),
  ask: @ui.Field::new(),
  asked: 0,
}

///|
/// Back to its words, no brief (whether it is on stays as it was): the chat started from it, or the app reset.
pub fn clarify_reset() -> Unit {
  clarify.asked += 1
  clarify.step.set(Writing)
  clarify.words.set("")
  clarify_fill({})
}

///|
/// The brief's four parts as the core answers them (`{goal, scope, accept, ask}`), each into its field.
pub fn clarify_fill(brief : Json) -> Unit {
  let b = Some(brief)
  clarify.goal.set(text(b, "goal"))
  clarify.scope.set(text(b, "scope"))
  clarify.accept.set(text(b, "accept"))
  clarify.ask.set(text(b, "ask"))
}

///|
/// Words `words` to be clarified on `station`: the page shows the brief being organized from now, the agent asked
/// for it (`newChat.clarify`); answered, the brief to edit; not, the page its words again, saying why and what is left
/// to do (send them as they are, or ask again).
pub fn clarify_start(src : Source, station : String, words : String) -> Unit {
  if src.read_only {
    toast_later(read_only_words)
    return
  }
  clarify.asked += 1
  let asked = clarify.asked
  clarify.words.set(words)
  clarify_fill({})
  clarify.step.set(Organizing)
  (src.call)("newChat.clarify", { "station": Json::string(station), "words": Json::string(words) }, fn(res) {
    // (asked again, or gone back to its words, since: nothing of it shown)
    guard asked == clarify.asked else { return }
    match res {
      Ok(brief) => {
        clarify_fill(brief)
        clarify.step.set(Ready)
      }
      Err(e) => {
        clarify.step.set(Writing)
        toast_later(@sf.t("web-main.newChat.clarify.failed", args=[("error", text(Some(e), "message"))]))
      }
    }
  })
}

///|
/// Back to the words it was asked of (返回修改): they are still in the composer, the brief let go.
pub fn clarify_back() -> Unit {
  clarify.asked += 1
  clarify.step.set(Writing)
}

///|
/// The brief as the chat's first message: each part that says something under its heading, in Markdown.
pub fn clarify_brief_text() -> String {
  let parts = [
    ("web-main.newChat.clarify.goal", clarify.goal),
    ("web-main.newChat.clarify.scope", clarify.scope),
    ("web-main.newChat.clarify.accept", clarify.accept),
    ("web-main.newChat.clarify.ask", clarify.ask),
  ]
  let out = StringBuilder()
  for part in parts {
    let (key, f) = part
    let words = f.text().trim(chars=" \n\t").to_owned()
    if words == "" {
      continue
    }
    if out.to_string() != "" {
      out.write_string("\n\n")
    }
    out.write_string("## " + @sf.t(key) + "\n\n" + words)
  }
  out.to_string()
}
