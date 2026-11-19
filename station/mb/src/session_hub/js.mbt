// What this package reads and makes of JSON as the TypeScript it is moved from does: a value's `String()`, a field
// that is undefined (absent) or null, JavaScript's `trim`, its counting of characters (code points) and its JSON text.

///|
pub using @jsjson {
  num_text as js_number_text, json_field as field, json_str_field as str_of, json_num_field as num_of,
  json_bool_field as is_true, json_items as items, code_points as chars, chars as take, js_index_of as index_of,
  js_split as split, js_replace_all as replace_all, json_opt_str as opt_str, json_num as num, json_int as int,
}

///|
pub using @jsjson {json_str_field as text_or_null}

///|
pub using @jscase {trim}

///|
/// `String(value)` as args.ts `jsString` has it: a string as it is, null as "null", anything else its JSON.
pub fn js_string(value : Json) -> String {
  match value {
    String(s) => s
    Null => "null"
    _ => js_json(value)
  }
}

///|
/// JSON.stringify of a value read from JSON (a number as JavaScript writes it).
pub fn js_json(value : Json) -> String {
  match value {
    Number(n, ..) => js_number_text(n)
    Array(items) => "[" + items.map(js_json).join(",") + "]"
    Object(map) => {
      let parts = []
      for k, v in map {
        parts.push(Json::string(k).stringify() + ":" + js_json(v))
      }
      "{" + parts.join(",") + "}"
    }
    _ => value.stringify()
  }
}

///|
/// Whether a value is a JSON object (not an array, not null).
pub fn is_object(v : Json) -> Bool {
  v is Object(_)
}

///|
/// `s.slice(from, to)` by UTF-16 units.
pub fn slice(s : String, from : Int, to? : Int = s.length()) -> String {
  @jsjson.js_slice(s, from, end=to)
}

///|
/// `a === b` for two JSON values read alike (deep for what JSON compares by value: used of strings, numbers, null).
pub fn same(a : Json?, b : Json?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => x == y
    _ => false
  }
}

///|
/// The UTF-16 unit at `i`, as an Int.
pub fn u(s : String, i : Int) -> Int {
  s.code_unit_at(i).to_int()
}
