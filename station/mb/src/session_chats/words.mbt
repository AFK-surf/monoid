// The words people read, in their language (station/src/ops/i18n.ts `tr`): the station part of client/i18n/catalog,
// given the program (each language's station.json); looked up, chosen and filled in as station/i18n says.

///|
pub struct Words {
  zh : J
  en : J
  product : String
}

///|
pub fn Words::new(zh : J, en : J, product? : String = "still.fail") -> Words {
  { zh, en, product }
}

///|
pub fn Words::empty() -> Words {
  { zh: Obj([]), en: Obj([]), product: "still.fail" }
}

///|
/// The words of `key` in `lang`, `args` filled in.
pub fn Words::tr(self : Words, lang : String, key : String, args? : Array[(String, String)] = []) -> String {
  @i18n.tr_jvalue(self.zh, self.en, self.product, lang, key, args~)
}

///|
fn json_map(v : J) -> Map[String, Json] {
  match v.to_json() {
    Object(m) => m
    _ => Map::new()
  }
}

///|
/// These words as `@session_hub.Words`, in `lang`.
pub fn Words::to_hub(self : Words, lang : String) -> @session_hub.Words {
  @session_hub.Words::new(zh=json_map(self.zh), en=json_map(self.en), lang~)
}
