// How old a core this station still answers (station/src/api/oldest.ts).

///|
pub let build_header : String = "stillfail-build"

///|
/// oldest.ts OLDEST_CORE.
pub let oldest_core : Int32 = 7917

///|
/// oldest.ts COUNTED_FROM: a build under it is held to no floor.
pub let counted_from : Int32 = 1000

///|
/// oldest.ts `buildOf`: the build `0.<m>.<n>` (or `<n>`) says.
pub fn build_of(said : String?) -> Double? {
  let s = @jscase.trim(said.unwrap_or(""))
  let digits = (v : StringView) => {
    v.length() > 0 && v.iter().all(c => c >= '0' && c <= '9')
  }
  let n = if digits(s.view()) {
    s
  } else if s.has_prefix("0.") {
    let rest = s.view(start_offset=2)
    match rest.find(".") {
      Some(dot) if digits(rest.view(end_offset=dot)) &&
        digits(rest.view(start_offset=dot + 1)) =>
        rest.view(start_offset=dot + 1).to_string()
      _ => return None
    }
  } else {
    return None
  }
  Some(js_number(n))
}

///|
/// oldest.ts `coreTooOld`.
pub fn core_too_old(
  headers : Array[(String, J)],
  oldest~ : Int32 = oldest_core,
) -> Bool {
  if oldest <= 0 {
    return false
  }
  let said = headers
    .iter()
    .find_first(h => @jscase.lower(h.0) == build_header)
    .map(h => h.1)
  let build = build_of(text_of(said))
  build is Some(b) && b >= counted_from.to_double() && b < oldest.to_double()
}
