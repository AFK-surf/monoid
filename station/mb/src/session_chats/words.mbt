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
