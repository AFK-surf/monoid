// The words people read on this machine, in the station's language (ops/i18n.ts `tr`): `{name}` takes the value given
// as `name`; `{"one", "other"}` is chosen by `n`. A key a language lacks is said in Chinese; one neither has is the key.

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
  let found = match (if lang == "en" { en.get(key) } else { None }) {
    Some(v) => Some(v)
    None => zh.get(key)
  }
  let text = match found {
    Some(String(s)) => s
    Some(Object(o)) => {
      let n = args.search_by(a => a.0 == "n").map(i => args[i].1.trim().to_owned())
      let pick = if n == Some("1") { o.get("one") } else { o.get("other") }
      match pick {
        Some(String(s)) => s
        _ =>
          match o.get("other") {
            Some(String(s)) => s
            _ => key
          }
      }
    }
    _ => key
  }
  fill(text, args)
}

///|
/// `{name}` filled; one not given, and a `{` that opens no name, left as they are.
fn fill(text : String, args : Array[(String, String)]) -> String {
  if args.length() == 0 || !text.contains("{") {
    return text
  }
  let out = StringBuilder()
  let mut i = 0
  let n = text.length()
  while i < n {
    let c = text.unsafe_charcode_at(i)
    if c == '{' {
      let mut j = i + 1
      while j < n {
        let d = text.unsafe_charcode_at(j)
        if (d >= 'A' && d <= 'Z') || (d >= 'a' && d <= 'z') || (d >= '0' && d <= '9') || d == '_' {
          j += 1
        } else {
          break
        }
      }
      if j < n && text.unsafe_charcode_at(j) == '}' {
        let name = text[i + 1:j].to_owned()
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
