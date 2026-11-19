// JSON as JavaScript reads and writes it (JSON.parse, JSON.stringify), through station/jsjson: what the TypeScript
// writes to a file and what it is answered are the same text here.

///|
pub using @jsjson {json_stringify as stringify, json_stringify_pretty as stringify_pretty}

///|
using @jsjson {
  jval_of_json as jvalue_of, json_at as field, json_field as get, json_str_field as text_at,
  json_num_field as num_at, json_arr_field as array_at, json_str as jstr, json_num as jnum, json_obj as jobj,
  json_arr as jarr, json_strs as jstrs, json_opt_str as opt_str_json, is_safe_integer as safe_int,
}

///|
/// JSON.parse(text): None where it is none.
pub fn parse(text : String) -> Json? {
  @jsjson.jval_try_parse(text).map(v => v.to_json())
}

///|
/// A stable sort in place (as JavaScript's Array.prototype.sort).
pub fn[T] stable_sort(xs : Array[T], cmp : (T, T) -> Int) -> Unit {
  let n = xs.length()
  if n < 2 {
    return
  }
  let tmp = xs.copy()
  let mut width = 1
  let mut src = xs
  let mut dst = tmp
  while width < n {
    let mut lo = 0
    while lo < n {
      let mid = if lo + width < n { lo + width } else { n }
      let hi = if lo + 2 * width < n { lo + 2 * width } else { n }
      let mut i = lo
      let mut j = mid
      let mut k = lo
      while k < hi {
        if i < mid && (j >= hi || cmp(src[i], src[j]) <= 0) {
          dst[k] = src[i]
          i += 1
        } else {
          dst[k] = src[j]
          j += 1
        }
        k += 1
      }
      lo += 2 * width
    }
    let t = src
    src = dst
    dst = t
    width *= 2
  }
  if !physical_equal(src, xs) {
    for i in 0..<n {
      xs[i] = src[i]
    }
  }
}

// ── reading a JSON value as the TypeScript does ─────────────────────────────────────────────────────────────────

///|
/// The object's own keys and values, as `Object.entries`.
fn entries_of_obj(v : Json?) -> Array[(String, Json)] {
  match v {
    Some(Object(m)) => m.iter().collect()
    _ => []
  }
}
