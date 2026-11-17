// The page round the app where it runs in a browser: the page's title, the colour the browser draws round it, and the
// browser's history of its site, which an app keeps in step with what it shows (a place put on as a page opens, the
// browser's back taken as the app's). Asked of the host through the app's own calls (@hostapi.app_said, app_tell,
// named `mbui.page.*`), which the browser's host answers itself (src/host/host_js.mbt, web/host.js) and every other
// host hands to an app that names none of them: nothing, and "" where it is. So the host's interface is as it was and
// nothing built on it is built again for it. Under a Tester: what it says is set (Tester::set_app_said
// "mbui.page.location"), what it is told kept (Tester::app_told).

///|
/// The title of the page (a browser's tab), as it changes.
pub fn set_title(title : String) -> Unit {
  @hostapi.app_tell("mbui.page.title", title)
}

///|
/// The colour of what the browser draws round the page (its bar, what shows past the page's edges), a CSS colour; ""
/// the page's own again.
pub fn set_theme_color(color : String) -> Unit {
  @hostapi.app_tell("mbui.page.theme_color", color)
}

///|
/// Where the page is in its site: its path, query and fragment (`/a?b#c`). "" where the app is in no page.
pub fn location() -> String {
  @hostapi.app_said("mbui.page.location")
}

///|
/// A place of the page's site put on the browser's history after the one it is at, the page there now (no load: the
/// app shows it).
pub fn history_push(to : String) -> Unit {
  @hostapi.app_tell("mbui.page.history_push", to)
}

///|
/// The place the browser's history is at put in place by `to` (no load).
pub fn history_replace(to : String) -> Unit {
  @hostapi.app_tell("mbui.page.history_replace", to)
}

///|
/// The browser's history taken a place back, as its back button does: where it comes to is said on `history_channel`.
pub fn history_back() -> Unit {
  @hostapi.app_tell("mbui.page.history_back", "")
}

///|
/// The channel a place the browser's history went to by itself (its back and forward, a person's swipe back,
/// `history_back`) is posted on, as `{"location": "/a?b#c"}` (`@ui.on_message(@webpage.history_channel, …)`); never
/// one the app put there (`history_push`, `history_replace`).
pub let history_channel : String = "history"
