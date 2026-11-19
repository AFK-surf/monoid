// The station's words (station/src/ops/i18n.ts `tr`): its catalog's station part in Chinese and English, each text
// already with its product's name (brand.ts `branded`), given whole by whoever runs the package (Node at a program's
// start, the test at the harness's), and the station's language; looked up, chosen and filled in as station/i18n says.

///|
pub struct Words {
  zh : Map[String, Json]
  en : Map[String, Json]
  lang : String
}

///|
pub fn Words::new(zh? : Map[String, Json] = {}, en? : Map[String, Json] = {}, lang? : String = "zh") -> Words {
  { zh, en, lang }
}

///|
/// i18n.ts `langOf`: Chinese for Chinese, English for any other; Chinese when nothing is said.
pub fn lang_of(locale : String?) -> String {
  let l = @jscase.lower(trim(locale.unwrap_or("")))
  if l == "" || l.has_prefix("zh") {
    "zh"
  } else {
    "en"
  }
}

///|
/// `tr(lang, key, args)`: the station's language unless `lang` is given.
pub fn Words::tr(self : Words, key : String, args? : Array[(String, Json)] = [], lang? : String) -> String {
  let args = args.map(a => (a.0, js_string(a.1)))
  @i18n.tr_json(self.zh, self.en, lang.unwrap_or(self.lang), key, args~)
}
