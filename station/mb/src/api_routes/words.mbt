// The words people read, in their language (station/src/ops/i18n.ts): the station part of client/i18n/catalog, given
// the program as it starts. `{name}` takes the value given as `name`; `{"one", "other"}` is chosen by `n` (1: one). A
// key a language lacks is said in Chinese; one neither has is the key. Where the station's cloud is another product's,
// still.fail's name standing alone is that product's (client/i18n/brand.ts `branded`).

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
fn word_char(c : Int32) -> Bool {
  (c >= '0' && c <= '9') ||
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  c == '_'
}

///|
/// still.fail's name standing alone made the product's: not after [\w./@-], not before [\w-] or a `.` and a \w.
fn branded(text : String, product : String) -> String {
  if product == "still.fail" || !text.contains("still.fail") {
    return text
  }
  let name = "still.fail"
  let out = StringBuilder::new()
  let mut i = 0
  while i < text.length() {
    if i + name.length() <= text.length() &&
      text.unsafe_substring(start=i, end=i + name.length()) == name {
      let before_ok = i == 0 ||
        ({
          let c = text.unsafe_charcode_at(i - 1)
          !(word_char(c) || c == '.' || c == '/' || c == '@' || c == '-')
        })
      let j = i + name.length()
      let after_ok = j >= text.length() ||
        ({
          let c = text.unsafe_charcode_at(j)
          !(word_char(c) ||
          c == '-' ||
          (
            c == '.' &&
            j + 1 < text.length() &&
            word_char(text.unsafe_charcode_at(j + 1))
          ))
        })
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
/// The words of `key` in `lang`, `args` filled in (each as `String(value)` says it).
pub fn Words::tr(
  self : Words,
  lang : String,
  key : String,
  args~ : Array[(String, String)] = [],
) -> String {
  let found = match
    jget(Some(if lang == "en" { self.en } else { self.zh }), key) {
    Some(f) => Some(f)
    None => jget(Some(self.zh), key)
  }
  let text = match found {
    Some(Str(u)) => u
    Some(Obj(_) as f) => {
      let n = args.iter().find_first(a => a.0 == "n")
      let one = match n {
        Some(a) => trim_js(a.1) == "1"
        None => false
      }
      let pick = if one { jstr(f.get("one")) } else { jstr(f.get("other")) }
      match pick {
        Some(t) => t
        None => jstr(f.get("other")).unwrap_or(key)
      }
    }
    _ => key
  }
  fill(branded(text, self.product), args)
}

///|
/// `{name}` filled; one not given, and a `{` that opens no name, left as they are.
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
        match args.iter().find_first(a => a.0 == name) {
          Some(a) => {
            out.write_string(a.1)
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
