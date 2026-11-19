// A failure notice reported from the chat (station/src/feedback/notice.ts, its 上报): a person who takes what went
// wrong for still.fail's own sends it to the team as a bug report, made here of what the station knows of it. POST
// /threads/:id/report `{n}` (the notice's entry), answered `{number, duplicate?}`. The store is the station's
// (`store`: getThread, entriesBetween, threadSessions, getSession, failedTurnsNear, listTurns, runtimeSessions); a
// line of the log has its homes scrubbed by ops/telemetry.ts `scrubPaths`.

///|
/// What the route is asked: the body, the asker's language and who they are (the admin API's request, as the route
/// reads it).
pub(all) struct ReportAsk {
  body : Bytes
  lang : String
  viewer : JV
}

///|
/// A route of the part: its method, its path's pattern, and what it answers (as the admin API's `Route`).
pub(all) struct ReportRoute {
  verb : String
  pattern : String
  handle : async (ReportAsk, Array[String?]) -> @api_routes.Answer
}

///|
/// The route, sending with `send`|
pub let report_path : String = "^/*threads/+([^/]+)/+report$"

///|
/// How much of the station's log is read back from its end, and how much of it goes with a report.
let log_tail : Int = 8 * 1024 * 1024

///|
let log_lines : Int = 300

///|
let log_most : Int = 48 * 1024

///|
let before_ms : Double = 60000.0

///|
let no_turn_ms : Double = 30.0 * 60000.0

///|
let after_ms : Double = 60000.0

///|
/// std::env::consts as Rust names them.
pub fn rust_arch(arch : String) -> String {
  match arch {
    "arm64" => "aarch64"
    "x64" => "x86_64"
    a => a
  }
}

///|
/// What a report is made with besides the store (notice.ts `ReportDeps`): the station's log as it ends (`logTail`),
/// the versions of the station and its runtimes (`versions`), the names of the variables its agents run with
/// (`envNames`), a session's page (`link`), and the home directory scrubbed from what is sent.
pub(all) struct ReportDeps {
  log_tail : async (Int) -> String?
  versions : async () -> JV
  env_names : async () -> Array[String]
  link : async (String) -> JV
  home : String
}

///|
/// `new Date(ms).toISOString()`.
pub fn iso_string(ms : Double) -> String {
  let secs = (ms / 1000.0).floor()
  let frac = (ms - secs * 1000.0).to_int()
  let f = frac.to_string()
  let f = "000".unsafe_substring(start=0, end=3 - f.length()) + f
  "\{@api_routes.iso_seconds(ms)}.\{f}Z"
}

///|
/// `Date.parse(s)` for the date-time string format (ISO 8601 as ECMAScript says it); NaN for what is not one. A time
/// with no zone is read as UTC, the station's own logs writing theirs with Z.
pub fn parse_iso(s : String) -> Double {
  let nan = 0.0 / 0.0
  let n = s.length()
  let mut i = 0
  let digits = (count : Int) => {
    if i + count > n {
      return None
    }
    let mut v = 0
    for k in 0..<count {
      let c = s.unsafe_charcode_at(i + k)
      if c < '0' || c > '9' {
        return None
      }
      v = v * 10 + (c - '0')
    }
    i += count
    Some(v)
  }
  let at = (c : Int) => i < n && s.unsafe_charcode_at(i) == c
  // the year: YYYY, or ±YYYYYY
  let year = if at('+') || at('-') {
    let neg = at('-')
    i += 1
    match digits(6) {
      Some(y) => if neg { if y == 0 { return nan } else { -y } } else { y }
      None => return nan
    }
  } else {
    match digits(4) {
      Some(y) => y
      None => return nan
    }
  }
  let mut month = 1
  let mut day = 1
  if at('-') {
    i += 1
    match digits(2) {
      Some(m) => month = m
      None => return nan
    }
    if at('-') {
      i += 1
      match digits(2) {
        Some(d) => day = d
        None => return nan
      }
    }
  }
  let mut hour = 0
  let mut minute = 0
  let mut second = 0
  let mut milli = 0.0
  let mut offset = 0
  if at('T') || at('t') {
    i += 1
    match digits(2) {
      Some(h) => hour = h
      None => return nan
    }
    if !at(':') {
      return nan
    }
    i += 1
    match digits(2) {
      Some(m) => minute = m
      None => return nan
    }
    if at(':') {
      i += 1
      match digits(2) {
        Some(sec) => second = sec
        None => return nan
      }
      if at('.') {
        i += 1
        let start = i
        let mut frac = 0.0
        let mut scale = 100.0
        while i < n &&
              s.unsafe_charcode_at(i) >= '0' &&
              s.unsafe_charcode_at(i) <= '9' {
          frac = frac + (s.unsafe_charcode_at(i) - '0').to_double() * scale
          scale = scale / 10.0
          i += 1
        }
        if i == start {
          return nan
        }
        milli = frac.floor()
      }
    }
    if at('Z') || at('z') {
      i += 1
    } else if at('+') || at('-') {
      let sign = if at('-') { -1 } else { 1 }
      i += 1
      let oh = match digits(2) {
        Some(h) => h
        None => return nan
      }
      if at(':') {
        i += 1
      }
      let om = match digits(2) {
        Some(m) => m
        None => return nan
      }
      if oh > 23 || om > 59 {
        return nan
      }
      offset = sign * (oh * 60 + om)
    }
  }
  if i != n {
    return nan
  }
  // (V8 takes a day up to 31 in any month, past its end into the next)
  if month < 1 || month > 12 || day < 1 || day > 31 {
    return nan
  }
  if hour > 24 ||
    minute > 59 ||
    second > 59 ||
    (hour == 24 && (minute > 0 || second > 0 || milli > 0.0)) {
    return nan
  }
  let days = @time.days_from_civil(year, month, day).to_double()
  days * 86400000.0 +
  hour.to_double() * 3600000.0 +
  minute.to_double() * 60000.0 +
  second.to_double() * 1000.0 +
  milli -
  offset.to_double() * 60000.0
}

///|
/// The station's log as it ends: its last `most` bytes, from the first whole line (notice.ts `readTail`).
pub async fn read_tail(b : ToolsBackend, path : String, most : Int) -> String? {
  let file = b.ask("fs.open", [js(path), js("r")]) catch { _ => return None }
  let name = ref_of(file).unwrap_or("")
  let out = {
    let size = jnumber(b.ask("\{name}.stat", []).get("size")).unwrap_or(0.0)
    let from = if size - most.to_double() > 0.0 {
      size - most.to_double()
    } else {
      0.0
    }
    let got = b.ask("\{name}.read", [jnum(0.0), jnum(size - from), jnum(from)])
    let n = jnumber(got.get("bytesRead")).unwrap_or(0.0).to_int()
    let bytes = @api_routes.bytes_of(got.get("buffer").unwrap_or(Null)).unwrap_or(
      b"",
    )
    let n = if n < bytes.length() { n } else { bytes.length() }
    let text = utf8_text(bytes[0:n].to_bytes())
    if from == 0.0 {
      text
    } else {
      slice(text, index_of(text, "\n") + 1)
    }
  } catch {
    e => {
      b.tell("\{name}.close", []) catch {
        _ => ()
      }
      raise e
    }
  }
  b.tell("\{name}.close", []) catch {
    _ => ()
  }
  Some(out)
}

///|
/// The session whose turn failed as the notice says (notice.ts `failedTurnOf`): of the thread's, the one whose failed
/// turn ended nearest before it; with no such turn, the thread's only session or its first.
pub async fn failed_turn_of(
  b : ToolsBackend,
  store : String,
  thread : JV,
  at : Double,
) -> (JV, JV)? {
  let sessions = []
  for m in jitems(Some(b.ask("\{store}.threadSessions", [thread]))) {
    let s = b.ask("\{store}.getSession", [field(m, "session")])
    match s {
      Null => ()
      x if is_undef(x) => ()
      Arr(items) => for x in items { sessions.push(x) }
      x => sessions.push(x)
    }
  }
  let from = at - 10.0 * 60000.0
  let to = at + 5000.0
  let bounded = is_safe_integer(at) && is_safe_integer(from) && is_safe_integer(to)
  let mut best : (JV, JV, Double)? = None
  for session in sessions {
    let turns = if bounded {
      b.ask("\{store}.failedTurnsNear", [
        field(session, "key"),
        jnum(from),
        jnum(to),
        jnum(at),
      ])
    } else {
      b.ask("\{store}.listTurns", [field(session, "key")])
    }
    for t in jitems(Some(turns)) {
      let summary = field(t, "summary")
      guard summary.get("outcome") is Some(Str("failed")) else { continue }
      guard summary.get("endedAt") is Some(Num(ended)) else { continue }
      let off = at - ended
      if off < -5000.0 || off > 10.0 * 60000.0 {
        continue
      }
      match best {
        Some((_, _, d)) if !(off.abs() < d) => ()
        _ => best = Some((session, summary, off.abs()))
      }
    }
  }
  match best {
    Some((s, t, _)) => Some((s, t))
    None => if sessions.length() > 0 { Some((sessions[0], Null)) } else { None }
  }
}

///|
fn is_word(c : Int) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '_'
}

///|
/// `^\S+\s+(WARN|ERROR) agents::<runtime>\b`.
fn own_line(line : String, runtime : String) -> Bool {
  let n = line.length()
  let mut i = 0
  while i < n && !is_js_space(line.unsafe_charcode_at(i)) {
    i += 1
  }
  if i == 0 {
    return false
  }
  let start = i
  while i < n && is_js_space(line.unsafe_charcode_at(i)) {
    i += 1
  }
  if i == start {
    return false
  }
  let rest = slice(line, i)
  let tail = if rest.has_prefix("WARN agents::") {
    slice(rest, 13)
  } else if rest.has_prefix("ERROR agents::") {
    slice(rest, 14)
  } else {
    return false
  }
  if !tail.has_prefix(runtime) {
    return false
  }
  let prev = if runtime == "" {
    ':'.to_int()
  } else {
    runtime.unsafe_charcode_at(runtime.length() - 1)
  }
  let next = if tail.length() > runtime.length() {
    Some(tail.unsafe_charcode_at(runtime.length()))
  } else {
    None
  }
  let next_word = match next {
    Some(c) => is_word(c)
    None => false
  }
  is_word(prev) != next_word
}

///|
/// The station's log lines about the session from `from` to `to` (notice.ts `logLines`).
pub async fn log_lines_of(
  b : ToolsBackend,
  text : String,
  from : Double,
  to : Double,
  names : Array[String],
  runtime : String,
  home : String,
) -> String {
  let cleaned = StringBuilder::new()
  for c in runtime {
    if is_word(c.to_int()) || c == '-' {
      cleaned.write_char(c)
    }
  }
  let runtime = cleaned.to_string()
  let kept = []
  for line in split(text, "\n") {
    let space = index_of(line, " ")
    let head = if space < 0 {
      slice(line, 0, to=-1)
    } else {
      slice(line, 0, to=space)
    }
    let at = parse_iso(head)
    if at.is_nan() || at < from || at > to {
      continue
    }
    if own_line(line, runtime) || names.iter().any(n => index_of(line, n) >= 0) {
      kept.push(said_text(b.ask("ops/telemetry.scrubPaths", [js(line), js(home)])))
    }
  }
  let mut out = if kept.length() > log_lines {
    kept[kept.length() - log_lines:].to_array()
  } else {
    kept
  }
  while out.length() > 0 && byte_length(out.join("\n")) > log_most {
    let cut = (out.length() + 9) / 10
    out = out[cut:].to_array()
  }
  out.join("\n")
}

///|
fn quoted_lines(text : String) -> String {
  split(text, "\n").map(l => "> \{l}").join("\n")
}

///|
/// The notice's text without its mark: `(text ?? "").replace(/^⚠️\s*/u, "").trim()`.
fn notice_text(t : String) -> String {
  let mark = "\u{26A0}\u{FE0F}"
  let s = if t.has_prefix(mark) {
    let mut i = mark.length()
    while i < t.length() && is_js_space(t.unsafe_charcode_at(i)) {
      i += 1
    }
    slice(t, i)
  } else {
    t
  }
  trim_js(s)
}

///|
/// The report of the notice `entry` in `thread`, reported by `viewer` (notice.ts `noticeReport`).
pub async fn notice_report(
  c : Ctx,
  store : String,
  thread : JV,
  entry : JV,
  viewer : JV,
  deps : ReportDeps,
) -> JV {
  let b = c.b
  let text = notice_text(
    match entry.get("text") {
      Some(Str(t)) => t
      _ => ""
    },
  )
  let entry_at = jnumber(entry.get("at")).unwrap_or(0.0)
  let found = failed_turn_of(b, store, field(thread, "id"), entry_at)
  let (session, turn) = match found {
    Some((s, t)) => (Some(s), if t is Null { None } else { Some(t) })
    None => (None, None)
  }
  // Titled by what failed as the runtime said it.
  let detail = match turn {
    Some(t) => jstr(t.get("detail"))
    None => None
  }
  let said = match detail {
    Some(d) if d != "" => d
    _ => text
  }
  let first = match split(said, "\n").iter().find_first(l => trim_js(l) != "") {
    Some(l) => trim_js(l)
    None => ""
  }
  let title = @api_routes.points(first)
  let title = (if title.length() > 200 { title[0:200].to_array() } else { title }).join(
    "",
  )
  let session_key = match session {
    Some(s) => js_string(s.get("key"))
    None => ""
  }
  let key = slice(
    @cloud_net.sha256_hex(
      "notice\n\{session_key}\n\{js_string(thread.get("id"))}\n\{js_string(entry.get("n"))}",
    ),
    0,
    to=32,
  )
  let versions = (deps.versions)()
  let env = (deps.env_names)()
  let turn_lines = match turn {
    Some(t) => {
      let started = jnumber(t.get("startedAt")).unwrap_or(0.0)
      let ended = match t.get("endedAt") {
        Some(Num(e)) => iso_string(e)
        _ => "?"
      }
      let lines = [
        "**Turn**: \{js_string(t.get("kind"))}, \{iso_string(started)} to \{ended}",
      ]
      match detail {
        Some(d) if d != "" => lines.push("**Failure**: \{d}")
        _ => ()
      }
      lines
    }
    None => ["**Turn**: none found"]
  }
  let agent_lines = match session {
    Some(s) => {
      let model = match s.get("model") {
        Some(Str(m)) if m != "" => ", model \{m}"
        _ => ""
      }
      [
        "**Agent**: \{js_string(s.get("runtime"))}, profile \{js_string(s.get("profile"))}\{model}",
      ]
    }
    None => []
  }
  let version_text = jfields(Some(versions))
    .map(p => "\{p.0} \{js_string(Some(p.1))}")
    .join(", ")
  let body = [
    "Reported from a failure notice in a chat (its 上报), by a person who takes it for a problem in still.fail.",
    "",
    "**Notice**",
    quoted_lines(text),
    "",
    "**When**: \{iso_string(entry_at)}",
    ..turn_lines,
    ..agent_lines,
    "**Versions**: \{if version_text == "" { "unknown" } else { version_text }}",
    "**Variables set for agents** (names only): \{if env.length() > 0 { env.join(", ") } else { "none" }}",
  ].join("\n")
  let context = [
    (
      "notice",
      jobj([("thread", field(thread, "id")), ("n", field(entry, "n"))]),
    ),
    ("os", js(c.consts.os)),
    ("arch", js(rust_arch(c.consts.arch))),
    ("software", versions),
    ("agentEnv", jstrs(env)),
  ]
  match session {
    Some(s) => {
      context.push(("session", field(s, "key")))
      context.push(("connect", field(s, "connect")))
      context.push(("runtime", field(s, "runtime")))
      context.push(("profile", field(s, "profile")))
      match s.get("model") {
        Some(Null) => ()
        m => context.push(("model", m.unwrap_or(jundef)))
      }
      let link = (deps.link)(session_key)
      if !(link is Null) {
        context.push(("link", link))
      }
    }
    None => ()
  }
  context.push(
    (
      "thread",
      js(
        "\{js_string(thread.get("channel"))}/\{js_string(thread.get("threadTs"))}",
      ),
    ),
  )
  let out = [
    ("key", js(key)),
    ("title", js(if title == "" { "failure notice" } else { title })),
    ("body", js(body)),
    ("area", js("station")),
    (
      "reporter",
      js(
        "\{js_string(viewer.get("name"))} (\{js_string(viewer.get("email"))}), from the chat",
      ),
    ),
    ("context", jobj(context)),
  ]
  match session {
    Some(s) if truthy(s.get("ws")) => out.push(("workspace", field(s, "ws")))
    _ => ()
  }
  match session {
    Some(s) =>
      match (deps.log_tail)(log_tail) {
        Some(tail) => {
          let started = match turn {
            Some(t) =>
              match t.get("startedAt") {
                Some(Num(v)) => v
                _ => entry_at - no_turn_ms
              }
            None => entry_at - no_turn_ms
          }
          let from = started - before_ms
          let names = [
            session_key,
            ..strings_of(Some(b.ask("\{store}.runtimeSessions", [js(session_key)]))),
            "profile=\{js_string(s.get("profile"))}",
          ]
          let logs = log_lines_of(
            b,
            tail,
            from,
            entry_at + after_ms,
            names,
            js_string(s.get("runtime")),
            deps.home,
          )
          if logs != "" {
            out.push(("logs", js(logs)))
          }
        }
        None => ()
      }
    None => ()
  }
  jobj(out)
}

///|
/// The route, sending with `send` (the feedback part's: to still.fail cloud, its answer `{number, duplicate?}`).
pub fn report_routes(
  c : Ctx,
  deps : ReportDeps,
  send : async (JV) -> JV,
  store? : String = "store",
) -> Array[ReportRoute] {
  let b = c.b
  [
    { verb: "POST", pattern: report_path, handle: (r, found) => {
      let raw = found.get(0).unwrap_or(None).unwrap_or("")
      let digits = raw != "" && raw.iter().all(ch => ch >= '0' && ch <= '9')
      let id = @api_routes.js_number(raw)
      let thread = if digits && is_safe_integer(id) {
        b.ask("\{store}.getThread", [jnum(id)])
      } else {
        Null
      }
      if thread is Null || is_undef(thread) {
        return @api_routes.error(404, "unknown thread \{raw}")
      }
      let n = if r.body.length() == 0 {
        None
      } else {
        match try_parse(utf8_text(r.body)) {
          None => return @api_routes.error(400, "invalid JSON")
          Some(v) =>
            match v {
              Obj(_) => v.get("n")
              _ => None
            }
        }
      }
      let n = match n {
        Some(Num(n)) if is_safe_integer(n) && n >= 1.0 => n
        _ => return @api_routes.error(400, c.tr(r.lang, "station.admin.badN"))
      }
      let entry = jitems(
        Some(b.ask("\{store}.entriesBetween", [field(thread, "id"), jnum(n), jnum(n)])),
      ).get(0)
      let failure = match entry {
        Some(e) =>
          e.get("authorKind") is Some(Str("station")) &&
          (match e.get("text") {
            Some(Str(t)) => t.has_prefix("\u{26A0}\u{FE0F}")
            _ => false
          })
        None => false
      }
      if !failure {
        return @api_routes.error(404, c.tr(r.lang, "station.feedback.notAFailure"))
      }
      let report = notice_report(c, store, thread, entry.unwrap(), r.viewer, deps)
      let answer = send(report) catch {
        e =>
          return @api_routes.error(
            502,
            c.tr(r.lang, "station.feedback.notSent", args=[("error", message_of(e))]),
          )
      }
      let number = match answer.get("number") {
        Some(Num(n)) if is_integer(n) && n >= 0.0 => n
        _ =>
          return @api_routes.error(
            502,
            c.tr(r.lang, "station.feedback.notSent", args=[
              ("error", stringify_or_undefined(answer)),
            ]),
          )
      }
      let fields = [("number", jnum(number))]
      if answer.get("duplicate") is Some(Bool(true)) {
        fields.push(("duplicate", jbool(true)))
      }
      @api_routes.json(200, stringify(jobj(fields)))
    } },
  ]
}

///|
/// JSON.stringify(v), "undefined" where v is undefined (as a template literal writes it).
pub fn stringify_or_undefined(v : JV) -> String {
  if is_undef(v) {
    "undefined"
  } else {
    stringify(v)
  }
}
