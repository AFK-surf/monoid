// What the last update brought, at the top of the chats' lists until it is seen (still.fail web/src/mobile/Changelog.tsx
// ChangelogNews; the `changelog` topic's `news`), where the frame puts it (the phone's Home: beside the wide frame's
// rail the web says it in a bubble of its own, cloud/workspace.tsx): the build it is now and its first three changes,
// a press opens the changelog; its × lets it go at once and tells the core (`changelog.seen`).

///|
/// The news let go here (before the core has it): none shows while the core's is this one; what shows it follows it.
let news_gone : @signals.Signal[Json?] = @signals.signal(None)

///|
/// As at the start (tests).
fn news_reset() -> Unit {
  news_gone.set(None)
}

///|
/// The changelog asked for its news alone (the core's `changelog` with `news`: no tab of it made or sent; the whole is
/// the changelog page's, 125 KB on a phone where this is a few hundred bytes, 2026-11-10).
pub fn news_params() -> Map[String, Json] {
  { "news": Json::boolean(true) }
}

///|
/// The news as the core has it, unless let go here.
pub fn news_of(src : Source) -> Json? {
  match field(src.topic("changelog", news_params()).get().value, "news") {
    Some(Object(_)) as n if news_gone.get() != n => n
    _ => None
  }
}

///|
/// How many of its changes it says before "还有 n 项".
let news_lines_most : Int = 3

///|
/// Whether the update wants the person over a small screen's list (update_card_node): the leave to install apps it waits
/// for (sfbase updates.mbt: a build ready that Android puts in place by itself once given it).
pub fn update_card_shown() -> Bool {
  @sfbase.update_now() is Allow(_)
}

