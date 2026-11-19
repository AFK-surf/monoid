// GET /events's query (station/src/api/routes/events.ts): what a stream is asked to follow.

///|
/// `Number(s)` of a string, as JavaScript reads one.
pub fn js_number(s : String) -> Double {
  @jsjson.js_number(s)
}

///|
/// Rust's `parse::<usize>()`: digits only, a leading + too.
fn usize(v : String?) -> Double? {
  guard v is Some(v) else { return None }
  let digits = if v.has_prefix("+") {
    v.view(start_offset=1).to_string()
  } else {
    v
  }
  if digits.length() == 0 || !digits.iter().all(c => c >= '0' && c <= '9') {
    return None
  }
  Some(js_number(v))
}

///|
fn all_of(query : Array[(String, String)], name : String) -> Array[String] {
  query.filter(p => p.0 == name).map(p => p.1)
}

///|
fn param(query : Array[(String, String)], name : String) -> String? {
  query.iter().find_first(p => p.0 == name).map(p => p.1)
}

///|
/// `^[0-9a-z]{1,40}$`: a login's id.
fn login_id(id : String) -> Bool {
  id.length() >= 1 &&
  id.length() <= 40 &&
  id.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z'))
}

///|
/// routes/events.ts: what a request's query asks a stream to follow, of the viewer's workspace only
/// (`session_seen`, `job_seen`; none: every one).
pub fn asked_of(
  query : Array[(String, String)],
  viewer : Viewer,
  session_exists : (String) -> Bool,
  store : SeenStore?,
) -> (Asked, String?) {
  let froms = all_of(query, "from")
  let lasts = all_of(query, "last")
  let live = []
  for i, key in all_of(query, "live") {
    let f = if i < froms.length() { Some(froms[i]) } else { None }
    let n = match f {
      Some(f) => js_number(f)
      None => @double.not_a_number
    }
    let from = match f {
      Some(f) if @jscase.trim(f) != "" && !n.is_nan() => {
        let m = if n > 0.0 { n } else { 0.0 }
        if m.is_inf() {
          m
        } else {
          m.floor()
        }
      }
      _ => 0.0
    }
    let last = usize(if i < lasts.length() { Some(lasts[i]) } else { None })
    let from = if from.is_inf() { 9007199254740991.0 } else { from }
    let last = match last {
      Some(l) if l > 0.0 => Some(l)
      _ => None
    }
    if session_exists(key) &&
      (store is None || session_seen(store.unwrap(), viewer, key)) {
      live.push((key, from, last))
    }
  }
  let lines = all_of(query, "lines")
  let logs = []
  for i, id in all_of(query, "job") {
    let asked = usize(if i < lines.length() { Some(lines[i]) } else { None }).unwrap_or(
      200.0,
    )
    let n = @cmp.minimum(1000.0, @cmp.maximum(1.0, asked))
    if store is None || job_seen(store.unwrap(), viewer, id) {
      logs.push((id, n.to_int()))
    }
  }
  let logins = if read_only(viewer.role) {
    []
  } else {
    all_of(query, "login").filter(login_id)
  }
  (
    {
      host: param(query, "host") == Some("1"),
      live,
      logs,
      since: param(query, "since"),
      brief: param(query, "brief") == Some("1"),
      logins,
      running: param(query, "running") == Some("1"),
    },
    None,
  )
}
