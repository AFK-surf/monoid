// JSON as the TypeScript it is written from reads and writes it (station/mb's jsjson: JSON.parse, JSON.stringify, an
// object's keys in the order they were put), and the few ways of reading a value the station's code goes by
// (`typeof v === "string"`, `Array.isArray`, a field of what may be anything).

///|
using @jsjson {type JValue as J}

///|
pub using @jsjson {
  jval_str as js, jval_num as jn, jval_int as ji, jval_bool as jb, jval_obj as jo, jval_array as ja,
  jval_strs as jsa, jval_opt_str as jopt, jval_at as at, jval_at_i as at_i, jval_str_of as str_of,
  jval_num_of as num_of, jval_bool_of as bool_of, jval_arr_of as arr_of, jval_nullish as nullish,
  jval_is_record as is_obj, jval_set as set_field, jval_spread as spread, stringify, jval_quote as quoted,
  points as chars, code_points as char_count, chars as first_chars, jval_stringify_num as num_text,
  jval_try_parse as parse_opt, jval_truthy as truthy,
}

///|
/// What the TypeScript threw: its message as it says it (`new Error(message)`), and of what kind where a caller tells
/// kinds apart (`instanceof Refused`, `PlaceRefused` with its code, `MessageWriteBusy`...); "" for a plain Error.
pub(all) suberror Thrown {
  Thrown(String, String)
}

///|
pub impl Show for Thrown with output(self, logger) {
  match self {
    Thrown(_, m) => logger.write_string(m)
  }
}

///|
/// A plain Error of `message`.
pub fn fail_(message : String) -> Thrown {
  Thrown("", message)
}

///|
pub fn thrown_message(e : Error) -> String {
  match e {
    Thrown(_, m) => m
    Failure(m) => m
    e => e.to_string()
  }
}

///|
pub fn thrown_kind(e : Error) -> String {
  match e {
    Thrown(k, _) => k
    _ => ""
  }
}

///|
pub fn is_null(v : J?) -> Bool {
  v is Some(Null)
}

///|
/// An object's own keys, as `Object.keys` gives them (the order jsjson keeps: integer-like ones first).
pub fn keys_of(v : J?) -> Array[String] {
  match v {
    Some(o) => @jsjson.jval_keys_of(o)
    None => []
  }
}

///|
/// An object without field `k` (`delete o[k]`, or a destructuring leaving it out).
pub fn without(o : J, ks : Array[String]) -> J {
  match o {
    Obj(fs) => Obj(fs.filter(f => !ks.contains(f.0)))
    other => other
  }
}

///|
/// The value parsed, or a thrown SyntaxError's message.
pub fn parse_js(text : String) -> J raise Thrown {
  @jsjson.parse(text) catch {
    @jsjson.SyntaxError(m) => raise Thrown("SyntaxError", m)
  }
}

///|
/// `a === b` for what JSON gives (an object or a list: the same where they hold the same, as the copies here are).
pub fn jeq(a : J, b : J) -> Bool {
  match (a, b) {
    (Null, Null) => true
    (Bool(x), Bool(y)) => x == y
    (Num(x), Num(y)) => x == y
    (Str(x), Str(y)) => x == y
    (Arr(xs), Arr(ys)) => xs.length() == ys.length() && xs.iter().zip(ys.iter()).all(p => jeq(p.0, p.1))
    (Obj(xs), Obj(ys)) =>
      xs.length() == ys.length() && xs.iter().zip(ys.iter()).all(p => p.0.0 == p.1.0 && jeq(p.0.1, p.1.1))
    _ => false
  }
}

///|
/// `xs.includes(v)`.
pub fn jincludes(xs : Array[J], v : J) -> Bool {
  xs.iter().any(x => jeq(x, v))
}

///|
/// What stands for `undefined` in what is said to the station.
pub fn undefined_j() -> J {
  jo([("$u", ji(1))])
}
