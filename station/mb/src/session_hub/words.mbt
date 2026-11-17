// The station's words (station/src/ops/i18n.ts `tr`): its catalog's station part in Chinese and English, each text
// already with its product's name (brand.ts `branded`), given whole by whoever runs the package (Node at a program's
// start, the test at the harness's), and the station's language. `{name}` takes the value given as `name`;
// `{"one", "other"}` is chosen by `n` (1: one). A key a language lacks is said in Chinese; one neither has is the key.

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
  let l = lang.unwrap_or(self.lang)
  let found = match (if l == "en" { self.en } else { self.zh }).get(key) {
    Some(f) => Some(f)
    None => self.zh.get(key)
  }
  let n = args.iter().find_first(a => a.0 == "n").map(a => trim(js_string(a.1)))
  let text = match found {
    Some(String(s)) => s
    Some(Object(_) as f) =>
      match (n, str_of(f, "one"), str_of(f, "other")) {
        (Some("1"), Some(one), _) => one
        (Some("1"), None, Some(other)) => other
        (_, _, Some(other)) => other
        _ => key
      }
    _ => key
  }
  fill(text, args)
}

///|
/// `{name}` filled; one not given, and a `{` that opens no name, left as they are.
fn fill(text : String, args : Array[(String, Json)]) -> String {
  if args.length() == 0 || !text.contains("{") {
    return text
  }
  let b = StringBuilder()
  let n = text.length()
  let mut i = 0
  while i < n {
    let c = u(text, i)
    if c == '{'.to_int() {
      let mut j = i + 1
      while j < n && name_unit(u(text, j)) {
        j += 1
      }
      if j < n && u(text, j) == '}'.to_int() {
        let name = slice(text, i + 1, to=j)
        match args.iter().find_first(a => a.0 == name) {
          Some((_, v)) => {
            b.write_string(js_string(v))
            i = j + 1
            continue
          }
          None => ()
        }
      }
    }
    b.write_char(Int::unsafe_to_char(c))
    i += 1
  }
  b.to_string()
}

///|
fn name_unit(c : Int) -> Bool {
  (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
  (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
  (c >= '0'.to_int() && c <= '9'.to_int()) ||
  c == '_'.to_int()
}
