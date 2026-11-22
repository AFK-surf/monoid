// The words people read, in their language (station/src/ops/i18n.ts): the station part of client/i18n/catalog, given
// the program as it starts; looked up, chosen and filled in as station/i18n says.

///|
pub struct Words {
  zh : JV
  en : JV
  /// The product's name (still.fail, or another's).
  product : String
}

///|
pub fn Words::new(zh : JV, en : JV, product~ : String = "still.fail") -> Words {
  { zh, en, product, }
}

///|
/// The words of `key` in `lang`, `args` filled in (each as `String(value)` says it).
pub fn Words::tr(
  self : Words,
  lang : String,
  key : String,
  args~ : Array[(String, String)] = [],
) -> String {
  @i18n.tr_jv(self.zh, self.en, self.product, lang, key, args~)
}
