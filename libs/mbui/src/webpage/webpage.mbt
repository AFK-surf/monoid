// The page round the app where it runs in a browser: the page's title, the colour the browser draws round it, the
// system's CJK faces its words are drawn in beside a face of the app's, and the browser's history of its site, which an app keeps in step with what it shows (a place put on as a page opens, the
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
/// The page's own title as it loaded (its `<title>`: what the site calls itself, before the run gave the page a title
/// of its own), "" where the app is in no page or the page had none.
pub fn loaded_title() -> String {
  @hostapi.app_said("mbui.page.loaded_title")
}

///|
/// The colour of what the browser draws round the page (its bar, what shows past the page's edges), a CSS colour; ""
/// the page's own again.
pub fn set_theme_color(color : String) -> Unit {
  @hostapi.app_tell("mbui.page.theme_color", color)
}

///|
/// The system's CJK faces drawn for the CJK marks of face `face` (a face given as style.mbt's faces are, 1 the words'):
/// each weight set `weight_step` heavier (a Latin face's 400 beside a CJK face's 400 reads thin and grey; clamped to
/// 100..900), by the system's faces named `families` (the first it has; none: PingFang SC, Noto Sans CJK SC, Source Han
/// Sans SC), the rest of the words in the face as ever. Where the face itself is not given, its CJK alone is drawn so,
/// once the system has any of them. Asked again, it takes the place of what it said before. Nothing where the page's
/// host has none (no browser).
pub fn set_cjk_face(face? : Int = 1, weight_step? : Int = 100, families? : Array[String] = []) -> Unit {
  let said : Json = {
    "face": Json::number(face.to_double()),
    "step": Json::number(weight_step.to_double()),
    "families": Json::array(families.map(Json::string)),
  }
  @hostapi.app_tell("mbui.page.cjk_face", said.stringify())
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
