// The words people read on this machine, in the station's language (ops/i18n.ts `tr`): looked up, chosen and filled
// in as station/i18n says.

///|
let catalogs : Ref[(Map[String, Json], Map[String, Json])?] = Ref(None)

///|
/// Both catalogs, parsed once.
pub fn catalogs_json() -> (Json, Json) {
  let (zh, en) = words_maps()
  (Json::object(zh), Json::object(en))
}

///|
fn words_maps() -> (Map[String, Json], Map[String, Json]) {
  match catalogs.val {
    Some(c) => c
    None => {
      let parse = (s : String) => match attempt(() => @json.parse(s)) {
        Ok(Object(m)) => m
        _ => Map([])
      }
      let c = (parse(station_zh), parse(station_en))
      catalogs.val = Some(c)
      c
    }
  }
}

///|
/// The station's language (config.json `language`): "zh" for Chinese or nothing said, "en" for any other.
pub fn lang_of(locale : String?) -> String {
  let l = match locale {
    Some(s) => s.trim().to_owned().to_lower()
    None => ""
  }
  if l == "" || l.has_prefix("zh") {
    "zh"
  } else {
    "en"
  }
}

///|
/// `tr(lang, key, args)`.
pub fn tr(lang : String, key : String, args? : Array[(String, String)] = []) -> String {
  let (zh, en) = words_maps()
  @i18n.tr_json(zh, en, lang, key, args~)
}
