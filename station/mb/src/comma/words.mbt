// The words people read, in their language (station/src/ops/i18n.ts `tr`): the station part of client/i18n/catalog,
// given the program (each language's station.json). `{name}` takes the value given as `name`; `{"one", "other"}` is
// chosen by `n` (1: one). A key a language lacks is said in Chinese; one neither has is the key. Where the station's
// cloud is another product's, still.fail's name standing alone is that product's (client/i18n/brand.ts `branded`).

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
fn word_char(c : Int) -> Bool {
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

///|
fn branded(text : String, product : String) -> String {
  if product == "still.fail" || !text.contains("still.fail") {
    return text
  }
  let name = "still.fail"
  let out = StringBuilder::new()
  let mut i = 0
  while i < text.length() {
    if i + name.length() <= text.length() && text.unsafe_substring(start=i, end=i + name.length()) == name {
      let before_ok = i == 0 ||
        {
          let c = text.unsafe_charcode_at(i - 1)
          !(word_char(c) || c == '.' || c == '/' || c == '@' || c == '-')
        }
      let j = i + name.length()
      let after_ok = j >= text.length() ||
        {
          let c = text.unsafe_charcode_at(j)
          !(word_char(c) || c == '-' || (c == '.' && j + 1 < text.length() && word_char(text.unsafe_charcode_at(j + 1))))
        }
      if before_ok && after_ok {
        out.write_string(product)
        i = j
        continue
      }
    }
    out.write_char(text.unsafe_charcode_at(i).unsafe_to_char())
    i += 1
  }
  out.to_string()
}

///|
fn trim_js(s : String) -> String {
  s.trim(chars=" \t\n\r\u{0b}\u{0c}\u{a0}\u{feff}\u{2028}\u{2029}").to_string()
}

///|
/// The words of `key` in `lang`, `args` filled in.
pub fn Words::tr(self : Words, lang : String, key : String, args? : Array[(String, String)] = []) -> String {
  let found = match prop(Some(if lang == "en" { self.en } else { self.zh }), key) {
    Some(f) => Some(f)
    None => prop(Some(self.zh), key)
  }
  let text = match found {
    Some(Str(u)) => @jsjson.text(u)
    Some(Obj(_) as f) => {
      let one = match args.search_by(a => a.0 == "n") {
        Some(i) => trim_js(args[i].1) == "1"
        None => false
      }
      let pick = if one { str_of(f.get("one")) } else { str_of(f.get("other")) }
      match pick {
        Some(t) => t
        None => str_of(f.get("other")).unwrap_or(key)
      }
    }
    _ => key
  }
  fill(branded(text, self.product), args)
}

///|
fn fill(text : String, args : Array[(String, String)]) -> String {
  if args.length() == 0 || !text.contains("{") {
    return text
  }
  let out = StringBuilder::new()
  let mut i = 0
  while i < text.length() {
    let c = text.unsafe_charcode_at(i)
    if c == '{' {
      let mut j = i + 1
      while j < text.length() && word_char(text.unsafe_charcode_at(j)) {
        j += 1
      }
      if j < text.length() && text.unsafe_charcode_at(j) == '}' {
        let name = text.unsafe_substring(start=i + 1, end=j)
        match args.search_by(a => a.0 == name) {
          Some(k) => {
            out.write_string(args[k].1)
            i = j + 1
            continue
          }
          None => ()
        }
      }
    }
    out.write_char(c.unsafe_to_char())
    i += 1
  }
  out.to_string()
}
