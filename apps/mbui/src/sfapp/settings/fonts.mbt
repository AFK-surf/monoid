// 外观 › 字体's state: the three places, the one in view, a place's face chosen (kept as the device's: `prefs.set
// {fonts}`, fetched whole by the app: src/sfapp/faces.mbt). The page is sfdesk's (font_setting.mbt), one for every
// frame.

///|
// kept across runs: a table, never written
pub let font_places : Array[String] = ["ui", "text", "code"]

///|
/// The place in view on the fonts page (its switch).
pub let fonts_at : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })

///|
/// Script layer in view on the fonts page: `0` Latin & digits (primary), `1` CJK & punctuation (companion).
pub let fonts_script_at : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })

///|
/// A place's face chosen (None: back to the app's own), kept as the device's.
pub fn set_font(core : Core, place : String, id : String?) -> Unit {
  let v = match id {
    Some(s) => ToJson::to_json(s)
    None => Json::null()
  }
  let fonts : Map[String, Json] = Map([])
  fonts[place] = v
  (core.call)("prefs.set", Json::object({ "fonts": Json::object(fonts) }), answer_unread)
}

///|
/// Apply a curated font pairing in one `prefs.set`: overwrites all 6 `fonts` slots (unused slots passed as `null`)
/// and optionally resets per-slot CJK optical scale/weight without touching reading typography settings.
pub fn set_fonts_preset(core : Core, fonts_patch : Map[String, Json], reset_cjk_optics? : Bool = true) -> Unit {
  let payload : Map[String, Json] = Map([])
  payload["fonts"] = Json::object(fonts_patch)
  if reset_cjk_optics {
    payload["typography"] = Json::object({
      "uiCjkScale": Json::null(),
      "textCjkScale": Json::null(),
      "codeCjkScale": Json::null(),
      "uiCjkWeight": Json::null(),
      "textCjkWeight": Json::null(),
      "codeCjkWeight": Json::null(),
    })
  }
  (core.call)("prefs.set", Json::object(payload), answer_unread)
}

///|
/// Update `prefs.typography` (`Json::null()` resets all typography settings to defaults, or an object patches keys).
pub fn set_typography(core : Core, patch : Json) -> Unit {
  (core.call)("prefs.set", Json::object({ "typography": patch }), answer_unread)
}
