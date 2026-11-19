// `JValue` as the packages make and read it: MoonBit's `Json` to and from it with nothing written and read again, and
// the small makers, readers and changes every package wrote alike. Each is JavaScript's own (`v.k`, `o[k] = v`,
// `{ ...a, ...b }`, `!!v`, `v == null`) where its doc says so; a package whose own differs keeps its own.

///|
/// MoonBit's JSON as JavaScript's value: an object's entries in the map's order.
pub fn JValue::of_json(v : Json) -> JValue {
  match v {
    Null => Null
    True => Bool(true)
    False => Bool(false)
    Number(n, ..) => Num(n)
    String(s) => Str(s)
    Array(xs) => Arr(xs.map(JValue::of_json))
    Object(m) => {
      let out = Array::new(capacity=m.length())
      for k, val in m {
        out.push((k, JValue::of_json(val)))
      }
      Obj(out)
    }
  }
}

///|
/// The value as MoonBit's JSON, what `@json.parse(stringify(v))` reads: NaN and the infinities as null, an object's
/// keys in JavaScript's order (integer-like ones first) and a repeated key's last value. A string's lone surrogates
/// are kept (as JSON.parse reads back the `\ud800` JSON.stringify writes), where `@json.parse` refuses that text whole;
/// `of_json` gives the same code units back.
pub fn JValue::to_json(self : JValue) -> Json {
  match self {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Num(n) => if n.is_nan() || n.is_inf() { Json::null() } else { Json::number(n) }
    Str(s) => Json::string(s)
    Arr(xs) => Json::array(xs.map(JValue::to_json))
    Obj(fs) => {
      let m : Map[String, Json] = Map([])
      for f in ordered(fs) {
        m[f.0] = f.1.to_json()
      }
      Json::object(m)
    }
  }
}

///|
pub fn JValue::of_string(s : String) -> JValue { Str(s) }

///|
pub fn JValue::of_double(d : Double) -> JValue { Num(d) }

///|
pub fn JValue::of_int(i : Int) -> JValue { Num(i.to_double()) }

///|
pub fn JValue::of_bool(b : Bool) -> JValue { Bool(b) }

///|
/// An object of these entries, in this order (a repeated key kept twice).
pub fn JValue::of_object(fields : Array[(String, JValue)]) -> JValue { Obj(fields) }

///|
pub fn JValue::of_array(items : Array[JValue]) -> JValue { Arr(items) }

///|
pub fn JValue::of_strings(items : Array[String]) -> JValue { Arr(items.map(JValue::of_string)) }

///|
/// The string, or null.
pub fn JValue::of_opt_string(s : String?) -> JValue {
  match s {
    Some(t) => Str(t)
    None => Null
  }
}

///|
/// `v[name]` where `v` is an object: a repeated key's first entry (`JValue::get`).
pub fn jval_at(v : JValue?, name : String) -> JValue? {
  match v {
    Some(Obj(_) as o) => o.get(name)
    _ => None
  }
}

///|
/// `v[i]` where `v` is an array and `i` within it.
pub fn jval_at_i(v : JValue?, i : Int) -> JValue? {
  match v {
    Some(Arr(xs)) => if i >= 0 && i < xs.length() { Some(xs[i]) } else { None }
    _ => None
  }
}

///|
/// A string's text (`sanitize_str`: a lone surrogate as U+FFFD), none for what is not a string.
pub fn jval_str_of(v : JValue?) -> String? {
  match v {
    Some(Str(s)) => Some(sanitize_str(s))
    _ => None
  }
}

///|
pub fn jval_num_of(v : JValue?) -> Double? {
  match v {
    Some(Num(d)) => Some(d)
    _ => None
  }
}

///|
pub fn jval_bool_of(v : JValue?) -> Bool? {
  match v {
    Some(Bool(b)) => Some(b)
    _ => None
  }
}

///|
pub fn jval_arr_of(v : JValue?) -> Array[JValue]? {
  match v {
    Some(Arr(xs)) => Some(xs)
    _ => None
  }
}

///|
/// An object's keys as its entries hold them (in their order, a repeated key twice); none for what is not an object.
/// `JValue::keys` is `Object.keys`'s order.
pub fn jval_keys_of(v : JValue) -> Array[String] {
  match v {
    Obj(fs) => fs.map(f => sanitize_str(f.0))
    _ => []
  }
}

///|
/// `v === true`.
pub fn jval_is_true(v : JValue?) -> Bool {
  v is Some(Bool(true))
}

///|
/// `o[k] = v` on an object: in its place where the key is there, at the end where it is not; what is not an object
/// is given back as it is.
pub fn jval_set(o : JValue, k : String, v : JValue) -> JValue {
  guard o is Obj(fs) else { return o }
  let out = fs.copy()
  match out.search_by(f => f.0 == k) {
    Some(i) => out[i] = (k, v)
    None => out.push((k, v))
  }
  Obj(out)
}

///|
/// `jval_set`, what is not an object taken as `{}`.
pub fn jval_set_or_new(o : JValue, k : String, v : JValue) -> JValue {
  jval_set(if o is Obj(_) { o } else { Obj([]) }, k, v)
}

///|
/// `delete o[k]` (each entry of that key); what is not an object is given back as it is.
pub fn jval_del(o : JValue, k : String) -> JValue {
  guard o is Obj(fs) else { return o }
  Obj(fs.filter(f => f.0 != k))
}

///|
/// `{ ...a, ...b }`: what is not an object adds nothing.
pub fn jval_spread(a : JValue, b : JValue) -> JValue {
  let out = match a {
    Obj(fs) => fs.copy()
    _ => []
  }
  if b is Obj(fs) {
    for f in fs {
      let k = sanitize_str(f.0)
      match out.search_by(e => e.0 == k) {
        Some(i) => out[i] = (k, f.1)
        None => out.push((k, f.1))
      }
    }
  }
  Obj(out)
}

///|
/// `!!v`, undefined (none) false.
pub fn jval_truthy(v : JValue?) -> Bool {
  match v {
    None | Some(Null) | Some(Bool(false)) => false
    Some(Num(n)) => n != 0.0 && !n.is_nan()
    Some(Str(s)) => s.length() > 0
    Some(_) => true
  }
}

///|
/// The value as MoonBit's JSON with well-formed strings (`sanitize_str`: lone surrogates as U+FFFD) and entries in
/// insertion order, numbers kept as given.
pub fn JValue::to_json_lossy(self : JValue) -> Json {
  match self {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Num(n) => Json::number(n)
    Str(s) => Json::string(sanitize_str(s))
    Arr(xs) => Json::array(xs.map(JValue::to_json_lossy))
    Obj(fs) => {
      let m : Map[String, Json] = Map([])
      for f in fs {
        m[sanitize_str(f.0)] = f.1.to_json_lossy()
      }
      Json::object(m)
    }
  }
}

///|
/// `JSON.parse(text)`, None where it throws.
pub fn jval_try_parse(text : String) -> JValue? {
  Some(parse(text)) catch {
    _ => None
  }
}

///|
/// `v[name]` where `v` is an object: a repeated key's last entry (as JSON.parse keeps it).
pub fn jval_at_last(v : JValue?, name : String) -> JValue? {
  match v {
    Some(Obj(fs)) => {
      let mut found = None
      for f in fs {
        if f.0 == name {
          found = Some(f.1)
        }
      }
      found
    }
    _ => None
  }
}

///|
/// `v?.[a]?.[b]…` (repeated key's first entry, via `jval_at`).
pub fn jval_at_path(v : JValue?, path : Array[String]) -> JValue? {
  let mut cur = v
  for k in path {
    cur = jval_at(cur, k)
  }
  cur
}

///|
/// `v?.[a]?.[b]…` (repeated key's last entry, via `jval_at_last`).
pub fn jval_at_path_last(v : JValue?, path : Array[String]) -> JValue? {
  let mut cur = v
  for k in path {
    cur = jval_at_last(cur, k)
  }
  cur
}

///|
/// `typeof v === "string" ? v : ""` (`text`: a lone surrogate as U+FFFD).
pub fn jval_text(v : JValue?) -> String {
  jval_str_of(v).unwrap_or("")
}

///|
/// The array's items, or `[]` for anything else.
pub fn jval_arr(v : JValue?) -> Array[JValue] {
  jval_arr_of(v).unwrap_or([])
}

///|
/// An object's entries as `(name, value)` pairs (`sanitize_str` on keys); `[]` for anything else.
pub fn jval_entries(v : JValue?) -> Array[(String, JValue)] {
  match v {
    Some(Obj(fs)) => fs.map(f => (sanitize_str(f.0), f.1))
    _ => []
  }
}

///|
/// `String(v)`, `None` (undefined) as `"undefined"`, `null` inside an array as `""`.
pub fn jval_js_str(v : JValue?) -> String {
  match v {
    None => "undefined"
    Some(Null) => "null"
    Some(Str(s)) => sanitize_str(s)
    Some(Bool(b)) => if b { "true" } else { "false" }
    Some(Num(d)) => num_text(d)
    Some(Arr(xs)) =>
      xs
      .map(x => match x {
        Null => ""
        _ => jval_js_str(Some(x))
      })
      .join(",")
    Some(Obj(_)) => "[object Object]"
  }
}

///|
/// `Number(v)` as JavaScript converts a value (`None` -> NaN, `Null` -> 0, `""` / `" "` -> 0, `[null]` -> 0).
pub fn jval_js_num(v : JValue?) -> Double {
  match v {
    None => @double.not_a_number
    Some(Null) => 0.0
    Some(Bool(b)) => if b { 1.0 } else { 0.0 }
    Some(Num(d)) => d
    Some(Str(s)) => js_number(sanitize_str(s))
    Some(Arr(xs)) =>
      match xs {
        [] => 0.0
        [Null] => 0.0
        [x] => js_number(jval_js_str(Some(x)))
        _ => @double.not_a_number
      }
    Some(Obj(_)) => @double.not_a_number
  }
}

///|
/// `Number.isInteger(v)`.
pub fn jval_is_integer(v : JValue?) -> Bool {
  v is Some(Num(d)) && is_integer(d)
}

///|
/// `Number.isSafeInteger(v)`.
pub fn jval_safe_int(v : JValue?) -> Bool {
  v is Some(Num(d)) && is_safe_integer(d)
}

///|
/// `v == null`, undefined (none) too.
pub fn jval_nullish(v : JValue?) -> Bool {
  v is (None | Some(Null))
}

///|
pub fn jval_of_json(v : Json) -> JValue { JValue::of_json(v) }

///|
pub fn jval_to_json(v : JValue) -> Json { v.to_json() }

///|
pub fn jval_to_json_lossy(v : JValue) -> Json { v.to_json_lossy() }

///|
pub fn jval_str(s : String) -> JValue { JValue::of_string(s) }

///|
pub fn jval_num(d : Double) -> JValue { JValue::of_double(d) }

///|
pub fn jval_int(i : Int) -> JValue { JValue::of_int(i) }

///|
pub fn jval_bool(b : Bool) -> JValue { JValue::of_bool(b) }

///|
pub fn jval_obj(fields : Array[(String, JValue)]) -> JValue { JValue::of_object(fields) }

///|
pub fn jval_array(items : Array[JValue]) -> JValue { JValue::of_array(items) }

///|
pub fn jval_strs(items : Array[String]) -> JValue { JValue::of_strings(items) }

///|
pub fn jval_opt_str(s : String?) -> JValue { JValue::of_opt_string(s) }

///|
pub fn jval_keys(v : JValue) -> Array[String] { v.keys() }

///|
/// `Array.isArray(v)`.
pub fn jval_is_arr(v : JValue?) -> Bool { v is Some(Arr(_)) }

///|
/// `typeof v === "object" && v !== null` (objects and arrays).
pub fn jval_is_obj(v : JValue?) -> Bool { v is Some(Obj(_) | Arr(_)) }

///|
/// Plain object (`Obj`, not `Arr`).
pub fn jval_is_record(v : JValue?) -> Bool { v is Some(Obj(_)) }

///|
/// Non-empty string (`sanitize_str`: lone surrogates as U+FFFD), else `None`.
pub fn jval_nonempty(v : JValue?) -> String? {
  match v {
    Some(Str(s)) if s.length() > 0 => Some(sanitize_str(s))
    _ => None
  }
}

///|
/// Finite number, else `None`.
pub fn jval_finite(v : JValue?) -> Double? {
  match v {
    Some(Num(d)) if is_finite(d) => Some(d)
    _ => None
  }
}

///|
/// Finite number, else `0.0`.
pub fn jval_finite_or_zero(v : JValue?) -> Double {
  match v {
    Some(Num(d)) if is_finite(d) => d
    _ => 0.0
  }
}

///|
/// `num_text(d)` for a number, `stringify(v)` otherwise.
pub fn jval_num_text_of(v : JValue) -> String {
  match v {
    Num(d) => num_text(d)
    _ => stringify(v)
  }
}

///|
/// `JSON.stringify(d)` (`"null"` for NaN and infinities).
pub fn jval_stringify_num(d : Double) -> String { stringify(Num(d)) }

///|
/// `typeof v === "string" && v === s` (`sanitize_str` on `v`).
pub fn jval_str_eq(v : JValue?, s : String) -> Bool {
  match v {
    Some(Str(u)) => sanitize_str(u) == s
    _ => false
  }
}

///|
pub fn jval_str_at(v : JValue?, name : String) -> String? { jval_str_of(jval_at(v, name)) }

///|
pub fn jval_num_at(v : JValue?, name : String) -> Double? { jval_num_of(jval_at(v, name)) }

///|
pub fn jval_bool_at(v : JValue?, name : String) -> Bool? { jval_bool_of(jval_at(v, name)) }

///|
pub fn jval_arr_at(v : JValue?, name : String) -> Array[JValue]? { jval_arr_of(jval_at(v, name)) }

///|
pub fn jval_strings_of(v : JValue?) -> Array[String] { jval_arr(v).filter_map(x => jval_str_of(Some(x))) }

///|
pub fn jval_same_opt(a : JValue?, b : JValue?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => stringify(x) == stringify(y)
    _ => false
  }
}

///|
pub fn jval_quote(s : String) -> String { stringify(JValue::of_string(s)) }

///|
/// `a < b` by UTF-16 code units.
pub fn js_less(a : String, b : String) -> Bool { js_compare(a, b) < 0 }

///|
pub fn json_str(s : String) -> Json { Json::string(s) }

///|
pub fn json_num(d : Double) -> Json { Json::number(d) }

///|
/// `Json::number(d)`, or `Json::null()` for NaN and infinities (as `JSON.stringify` writes them).
pub fn json_num_js(d : Double) -> Json {
  if d.is_nan() || d.is_inf() {
    Json::null()
  } else {
    Json::number(d)
  }
}

///|
pub fn json_int(i : Int) -> Json { Json::number(i.to_double()) }

///|
pub fn json_int64(i : Int64) -> Json { Json::number(i.to_double()) }

///|
pub fn json_bool(b : Bool) -> Json { Json::boolean(b) }

///|
pub fn json_arr(items : Array[Json]) -> Json { Json::array(items) }

///|
pub fn json_strs(items : Array[String]) -> Json { Json::array(items.map(Json::string)) }

///|
pub fn json_obj(fields : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for f in fields {
    m[f.0] = f.1
  }
  Json::object(m)
}

///|
pub fn json_opt_str(s : String?) -> Json {
  match s {
    Some(t) => Json::string(t)
    None => Json::null()
  }
}

///|
pub fn json_at(v : Json?, k : String) -> Json? {
  match v {
    Some(Object(m)) => m.get(k)
    _ => None
  }
}

///|
pub fn json_field(v : Json, k : String) -> Json? {
  match v {
    Object(m) => m.get(k)
    _ => None
  }
}

///|
pub fn json_str_of(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
pub fn json_num_of(v : Json?) -> Double? {
  match v {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
pub fn json_bool_of(v : Json?) -> Bool? {
  match v {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
pub fn json_arr_of(v : Json?) -> Array[Json]? {
  match v {
    Some(Array(xs)) => Some(xs)
    _ => None
  }
}

///|
pub fn json_strings_of(v : Json?) -> Array[String] {
  match v {
    Some(Array(a)) =>
      a.filter_map(x => match x {
        String(s) => Some(s)
        _ => None
      })
    _ => []
  }
}

///|
pub fn json_str_at(v : Json?, k : String) -> String? { json_str_of(json_at(v, k)) }

///|
pub fn json_num_at(v : Json?, k : String) -> Double? { json_num_of(json_at(v, k)) }

///|
pub fn json_bool_at(v : Json?, k : String) -> Bool? { json_bool_of(json_at(v, k)) }

///|
pub fn json_arr_at(v : Json?, k : String) -> Array[Json]? { json_arr_of(json_at(v, k)) }

///|
pub fn json_is_obj(v : Json?) -> Bool { v is Some(Object(_)) }

///|
pub fn json_is_objectish(v : Json?) -> Bool { v is Some(Object(_) | Array(_)) }

///|
pub fn json_finite(v : Json?) -> Double? {
  match v {
    Some(Number(n, ..)) if is_finite(n) => Some(n)
    _ => None
  }
}

///|
pub fn jval_or_null(v : JValue?) -> JValue { v.unwrap_or(Null) }

///|
pub fn jval_str_raw_of(v : JValue?) -> String? { jstr(v) }

///|
pub fn jval_js_str_raw(v : JValue) -> String { js_string(v) }

///|
pub fn json_stringify(v : Json) -> String { stringify(JValue::of_json(v)) }

///|
pub fn json_stringify_pretty(v : Json) -> String { stringify_indent(JValue::of_json(v), 2) }

///|
pub fn json_js_str(v : Json?) -> String {
  match v {
    None => "undefined"
    Some(Null) => "null"
    Some(True) => "true"
    Some(False) => "false"
    Some(Number(d, ..)) => num_text(d)
    Some(String(s)) => s
    Some(Array(a)) =>
      a
      .map(x => match x {
        Null => ""
        _ => json_js_str(Some(x))
      })
      .join(",")
    Some(Object(_)) => "[object Object]"
  }
}

///|
pub fn json_items(v : Json?) -> Array[Json] {
  match v {
    Some(Array(a)) => a
    _ => []
  }
}

///|
pub fn json_str_field(v : Json, k : String) -> String? { json_str_of(json_field(v, k)) }

///|
pub fn json_num_field(v : Json, k : String) -> Double? { json_num_of(json_field(v, k)) }

///|
pub fn json_bool_field(v : Json, k : String) -> Bool { json_field(v, k) is Some(True) }

///|
pub fn json_arr_field(v : Json, k : String) -> Array[Json]? { json_arr_of(json_field(v, k)) }

///|
pub fn json_truthy(v : Json?) -> Bool {
  match v {
    None | Some(Null) | Some(False) => false
    Some(Number(n, ..)) => !(n == 0.0 || n.is_nan())
    Some(String(s)) => s != ""
    _ => true
  }
}

///|
pub fn json_nullish(v : Json?) -> Bool { v is (None | Some(Null)) }

///|
pub fn json_same_opt(a : Json?, b : Json?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => json_stringify(x) == json_stringify(y)
    _ => false
  }
}

///|
pub fn js_trunc(d : Double) -> Double {
  if d < 0.0 {
    d.ceil()
  } else {
    d.floor()
  }
}

///|
pub fn js_uniq(xs : Array[String]) -> Array[String] {
  let seen : Map[String, Unit] = Map([])
  let out = []
  for x in xs {
    if !seen.contains(x) {
      seen[x] = ()
      out.push(x)
    }
  }
  out
}

///|
pub fn js_all_digits(s : String) -> Bool {
  if s == "" {
    return false
  }
  for i in 0..<s.length() {
    let c = s.code_unit_at(i).to_int()
    if c < 48 || c > 57 {
      return false
    }
  }
  true
}

///|
pub fn js_upper_ascii(s : String) -> String {
  let b = StringBuilder()
  for i in 0..<s.length() {
    let c = s.code_unit_at(i).to_int()
    b.write_char(Int::unsafe_to_char(if c >= 97 && c <= 122 { c - 32 } else { c }))
  }
  b.to_string()
}

///|
pub fn js_split_lines(s : String) -> Array[String] {
  js_split(s, "\n").map(l => if l.has_suffix("\r") { l.unsafe_substring(start=0, end=l.length() - 1) } else { l })
}

///|
pub fn js_slice_to(s : String, n : Int) -> String {
  if n <= 0 {
    ""
  } else if s.length() <= n {
    s
  } else {
    s.unsafe_substring(start=0, end=n)
  }
}

///|
pub fn js_replace_all(s : String, old : String, new : String) -> String { js_split(s, old).join(new) }

///|
/// `Buffer.byteLength(s, "utf8")`: a lone surrogate is 3 bytes (U+FFFD), without allocating.
pub fn js_utf8_len(s : String) -> Int {
  let mut n = 0
  let mut i = 0
  while i < s.length() {
    let c = s.unsafe_get(i).to_int()
    if c < 0x80 {
      n += 1
    } else if c < 0x800 {
      n += 2
    } else if c >= 0xd800 && c <= 0xdbff && i + 1 < s.length() {
      let d = s.unsafe_get(i + 1).to_int()
      if d >= 0xdc00 && d <= 0xdfff {
        n += 4
        i += 1
      } else {
        n += 3
      }
    } else {
      n += 3
    }
    i += 1
  }
  n
}

///|
pub fn js_starts(s : String, p : String) -> Bool { s.has_prefix(p) }

///|
pub fn js_ends(s : String, p : String) -> Bool { s.has_suffix(p) }

///|
pub fn js_includes(s : String, p : String) -> Bool { s.contains(p) }
