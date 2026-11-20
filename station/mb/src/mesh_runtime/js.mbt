// What the TypeScript this package is written from leans on of JavaScript itself: `String.prototype.trim`'s
// whitespace, `Number(string)`, `String(number)`, `Math.round`, `>>> 0` and `JSON.stringify`, so what is worked out
// here is the same to the code unit.

///|
pub using @jscase {is_space as js_space, trim as js_trim}

///|
pub using @jsjson {
  js_number, is_integer as js_is_integer, js_round, num_text as js_num, jval_of_json as jvalue,
  jval_quote as js_quote,
}

///|
using @jsjson {
  json_num as jnum, json_str as jstr, json_obj as jobj, json_field as field, json_num_of as num_of,
  json_str_of as str_of, json_finite as finite,
}

///|
fn is_digit(c : Int) -> Bool {
  c >= 0x30 && c <= 0x39
}

///|
/// `n >>> 0`: ToUint32, as a Double.
pub fn to_uint32(n : Double) -> Double {
  if n.is_nan() || n == @double.infinity || n == @double.neg_infinity {
    return 0.0
  }
  let t = n.trunc()
  let m = 4294967296.0
  let r = t - (t / m).floor() * m
  if r == m {
    0.0
  } else {
    r
  }
}

///|
/// `JSON.stringify(v)` of a value read from JSON. (An object's integer-like keys first, as JavaScript keeps them.)
pub fn js_stringify(v : Json) -> String {
  let text = @jsjson.stringify(jvalue(v))
  // through JavaScript's own reading, so its keys' order is its
  @jsjson.stringify(@jsjson.parse(text)) catch {
    _ => text
  }
}
