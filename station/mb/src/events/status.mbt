// The local status (station/src/api/status.ts): what the station is doing, for a program on this machine (a status
// display, the Monoid Machine's monoid-agent), on a Unix socket of its data directory: whether it is enrolled, how many
// agents are at work and how many there are, whether one waits for a person, and the tasks behind those numbers.

///|
/// status.ts WAITING_DAYS, TASKS_MOST, SETTLE_MS.
pub let waiting_days : Double = 7.0

///|
pub let tasks_most : Int32 = 50

///|
pub let settle_ms : Double = 500.0

///|
/// What the status is made of (status.ts `StatusInput`): the control plane's state (cloud.json; none: none), whether
/// it is heard, the running sessions (`key`, `title`, `since`), each live process's state, the sessions waiting for a
/// person (`key`, `title`, `need`, `endedAt`), and how the process reaches devices.
pub(all) struct StatusInput {
  version : String
  cloud : J?
  reached : Bool
  running : Array[J]
  processes : Array[(String, String)]
  waiting : Array[J]
  health : J?
}

///|
/// `a.sort(compare)` as JavaScript sorts: stable.
fn stable_sort(items : Array[J], before : (J, J) -> Double) -> Array[J] {
  let out = items.copy()
  for i in 1..<out.length() {
    let x = out[i]
    let mut k = i - 1
    while k >= 0 && before(out[k], x) > 0.0 {
      out[k + 1] = out[k]
      k -= 1
    }
    out[k + 1] = x
  }
  out
}

///|
/// `v || null`.
fn or_null(v : J?) -> J {
  if truthy(v) {
    v.unwrap()
  } else {
    Null
  }
}

///|
/// status.ts `statusOf`.
pub fn status_of(i : StatusInput) -> J {
  let c = match i.cloud {
    Some(Null) => None
    other => other
  }
  let cf = (name : String) => {
    match c {
      Some(c) => c.get(name)
      None => None
    }
  }
  let enrolled = c is Some(_) &&
    truthy(cf("workspace")) &&
    cf("removed_at") is None
  let busy : Map[String, Unit] = Map([])
  for r in i.running {
    busy[string_of(r.get("key"))] = ()
  }
  for p in i.processes {
    if p.1 == "running" {
      busy[p.0] = ()
    }
  }
  let warm = i.processes
    .filter(p => p.1 == "warm" && !busy.contains(p.0))
    .map(p => p.0)
  let waiting = i.waiting.filter(w => !busy.contains(string_of(w.get("key"))))
  let all : Map[String, Unit] = Map([])
  for k, _ in busy {
    all[k] = ()
  }
  for k in warm {
    all[k] = ()
  }
  for w in waiting {
    all[string_of(w.get("key"))] = ()
  }
  let since_of = (r : J) => {
    match r.get("since") {
      Some(Num(n)) => n
      _ => 0.0
    }
  }
  let working = stable_sort(i.running, (a, b) => since_of(b) - since_of(a)).map(r => {
      jo([
        ("session", r.get("key").unwrap_or(Null)),
        ("title", r.get("title").unwrap_or(Null)),
        ("state", js("working")),
        ("since", r.get("since").unwrap_or(Null)),
        ("need", Null),
      ])
    },
  )
  for key, _ in busy {
    if !i.running.iter().any(r => string_of(r.get("key")) == key) {
      working.push(
        jo([
          ("session", js(key)),
          ("title", Null),
          ("state", js("working")),
          ("since", Null),
          ("need", Null),
        ]),
      )
    }
  }
  let waits = waiting.map(w => {
    jo([
      ("session", w.get("key").unwrap_or(Null)),
      ("title", w.get("title").unwrap_or(Null)),
      ("state", js("waiting")),
      ("since", w.get("endedAt").unwrap_or(Null)),
      ("need", w.get("need").unwrap_or(Null)),
    ])
  })
  let tasks = working + waits
  jopt([
    ("version", Some(js(i.version))),
    ("enrolled", Some(Bool(enrolled))),
    ("origin", Some(or_null(cf("origin")))),
    ("workspace", Some(or_null(cf("workspace")))),
    ("workspaceName", Some(or_null(cf("workspace_name")))),
    ("station", Some(or_null(cf("station")))),
    ("reached", Some(Bool(i.reached))),
    (
      "agents",
      Some(
        jo([
          ("busy", jn(busy.length().to_double())),
          ("warm", jn(warm.length().to_double())),
          ("total", jn(all.length().to_double())),
        ]),
      ),
    ),
    ("waiting", Some(jn(waiting.length().to_double()))),
    (
      "tasks",
      Some(
        ja(
          if tasks.length() > tasks_most {
            tasks[0:tasks_most].to_owned()
          } else {
            tasks
          },
        ),
      ),
    ),
    (
      "health",
      match i.health {
        Some(Null) | None => None
        Some(h) => if truthy(Some(h)) { Some(h) } else { None }
      },
    ),
  ])
}

///|
/// What a request on the socket is answered (status.ts `StatusRoute`).
pub(all) enum StatusRoute {
  Status
  Watch
  Health
  NotFound
}

///|
/// The path and query of a request's target as `new URL(url, "http://station")` reads them: `\` as `/`, `//host`
/// naming a host, `.` and `..` worked out, a fragment let go.
fn url_parts(url : String) -> (String, String) {
  let url = url.replace_all(old="\\", new="/")
  let url = match url.find("#") {
    Some(h) => url.view(end_offset=h).to_string()
    None => url
  }
  let (path, query) = match url.find("?") {
    Some(q) =>
      (
        url.view(end_offset=q).to_string(),
        url.view(start_offset=q + 1).to_string(),
      )
    None => (url, "")
  }
  let path = if path.has_prefix("//") {
    let rest = path.view(start_offset=2)
    match rest.find("/") {
      Some(s) => rest.view(start_offset=s).to_string()
      None => "/"
    }
  } else if path.has_prefix("/") {
    path
  } else {
    "/" + path
  }
  let out : Array[String] = []
  let parts = path
    .view(start_offset=1)
    .split("/")
    .map(p => p.to_string())
    .to_array()
  for k, part in parts {
    let lower = @jscase.lower(part)
    let last = k == parts.length() - 1
    if lower == "." || lower == "%2e" {
      if last {
        out.push("")
      }
    } else if lower == ".." ||
      lower == ".%2e" ||
      lower == "%2e." ||
      lower == "%2e%2e" {
      if out.length() > 0 {
        let _ = out.pop()
      }
      if last {
        out.push("")
      }
    } else {
      out.push(part)
    }
  }
  ("/" + out.join("/"), query)
}

///|
/// URLSearchParams `get`: the first value of `name`, `+` a space and percents decoded.
fn search_param(query : String, name : String) -> String? {
  for pair in query.split("&") {
    let pair = pair.to_string()
    if pair == "" {
      continue
    }
    let (k, v) = match pair.find("=") {
      Some(e) =>
        (
          pair.view(end_offset=e).to_string(),
          pair.view(start_offset=e + 1).to_string(),
        )
      None => (pair, "")
    }
    if percent_decode(k) == name {
      return Some(percent_decode(v))
    }
  }
  None
}

///|
/// status.ts `routeOf`.
pub fn route_of(verb : String?, url : String?) -> StatusRoute {
  if verb != Some("GET") {
    return NotFound
  }
  let (path, query) = url_parts(url.unwrap_or("/"))
  if path == "/healthz" {
    return Health
  }
  if path != "/v1/status" {
    return NotFound
  }
  match search_param(query, "watch") {
    Some(w) if w != "0" && w != "false" => Watch
    _ => Status
  }
}

///|
/// status.ts `statusServer`'s telling: what each watcher is written as the status changes, a burst said once
/// (SETTLE_MS after its first), nothing said twice alike. `now` makes the status (raising: the station is starting).
pub struct StatusTeller {
  now : () -> J?
  after : (Double, () -> Unit) -> () -> Unit
  watchers : Map[Int32, (String) -> Unit]
  mut next : Int32
  mut last : String
  mut pending : (() -> Unit)?
}

///|
pub fn StatusTeller::new(
  now : () -> J?,
  after : (Double, () -> Unit) -> () -> Unit,
) -> StatusTeller {
  { now, after, watchers: Map([]), next: 0, last: "", pending: None, }
}

///|
fn StatusTeller::tell(self : StatusTeller) -> Unit {
  self.pending = None
  if self.watchers.length() == 0 {
    return
  }
  guard (self.now)() is Some(status) else { return }
  let text = stringify(status)
  if text == self.last {
    return
  }
  self.last = text
  for _, write in self.watchers {
    write("\{text}\n")
  }
}

///|
/// Something the status is made of changed.
pub fn StatusTeller::changed(self : StatusTeller) -> Unit {
  if self.watchers.length() == 0 || self.pending is Some(_) {
    return
  }
  self.pending = Some((self.after)(settle_ms, () => self.tell()))
}

///|
/// A request's answer: its status, content type and body (status.ts's server); a watch's first line, then `write`
/// given each change until the returned function is called.
pub fn StatusTeller::answer(
  self : StatusTeller,
  route : StatusRoute,
  write : (String) -> Unit,
) -> (Int32, String, String, (() -> Unit)?) {
  match route {
    NotFound => (404, "application/json", "{\"error\":\"not found\"}", None)
    Health => (200, "text/plain", "ok\n", None)
    _ =>
      match (self.now)() {
        None =>
          (
            503,
            "application/json",
            stringify(jo([("error", js("the station is starting; ask again"))])),
            None,
          )
        Some(status) => {
          let text = stringify(status)
          if route is Status {
            return (200, "application/json", "\{text}\n", None)
          }
          self.last = text
          self.next += 1
          let id = self.next
          self.watchers[id] = write
          (
            200,
            "application/x-ndjson",
            "\{text}\n",
            Some(() => self.watchers.remove(id)),
          )
        }
      }
  }
}

///|
pub fn StatusTeller::close(self : StatusTeller) -> Unit {
  if self.pending is Some(stop) {
    stop()
  }
  self.pending = None
  self.watchers.clear()
}
