// What a copy of a station's conversations is made of (format.ts): batches, a generation of them, and the head that
// says which batches and files make the copy now. A head is kept as it was read (`J`), its fields read by name.

///|
/// The batches' format: a restorer takes those of its own version or before.
pub let format_version : Double = 1.0

///|
/// When a generation began, from its name (base 36, then a random part): `parseInt(gen.split("-")[0], 36)`.
pub fn gen_made(gen : String) -> Double {
  let mut n = 0.0
  let mut any = false
  for i in 0..<gen.length() {
    let c = gen.unsafe_charcode_at(i)
    let d = if c >= '0' && c <= '9' {
      c - '0'
    } else if c >= 'a' && c <= 'z' {
      c - 'a' + 10
    } else if c >= 'A' && c <= 'Z' {
      c - 'A' + 10
    } else {
      break
    }
    n = n * 36.0 + d.to_double()
    any = true
  }
  if any {
    n
  } else {
    @double.not_a_number
  }
}

///|
fn safe_integer(v : J?) -> Bool {
  match v {
    Some(Num(n)) => n == n.floor() && n.abs() <= 9007199254740991.0
    _ => false
  }
}

///|
/// A head read back, or None where it is none (or of a format newer than this).
pub fn as_head(v : J) -> J? {
  guard v is Obj(_) else { return None }
  guard num_at(v, "v") is Some(ver) && !(ver > format_version) else { return None }
  guard at(v, "origin") is Some(Str(_)) && at(v, "workspace") is Some(Str(_)) else { return None }
  guard str_at(v, "gen") is Some(gen) && is_gen(gen) else { return None }
  if !safe_integer(at(v, "to")) {
    return None
  }
  guard at(v, "batches") is Some(Arr(batches)) else { return None }
  for b in batches {
    guard str_of(Some(b)) is Some(name) && is_batch(name) else { return None }
  }
  guard at(v, "files") is Some(Obj(files)) else { return None }
  for f in files {
    if !is_hash(@jsjson.sanitize_str(f.0)) {
      return None
    }
  }
  guard at(v, "runs") is Some(Arr(_)) else { return None }
  Some(v)
}

///|
pub fn head_gen(h : J) -> String {
  text_at(h, "gen")
}

///|
pub fn head_to(h : J) -> Double {
  num_at(h, "to").unwrap_or(0.0)
}

///|
pub fn head_made(h : J) -> Double {
  num_at(h, "made").unwrap_or(0.0)
}

///|
pub fn head_batches(h : J) -> Array[String] {
  strings_of(at(h, "batches"))
}

///|
/// `Object.keys(head.files)`.
pub fn head_files(h : J) -> Array[String] {
  entries(at(h, "files")).map(e => e.0)
}

///|
pub fn head_runs(h : J) -> Array[(String, Double)] {
  items(at(h, "runs")).map(r => (text_at(r, "run"), num_at(r, "from").unwrap_or(0.0)))
}
