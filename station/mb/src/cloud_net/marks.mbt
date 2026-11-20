// What a station is called and the mark it shows (its name, an emoji or an icon), kept by the station itself
// (station/src/mesh/station-marks.ts; the user, 2026-11-14: 「谁看都存在 station 上」): one record a station, the same in
// every workspace it is in, changed only on the station it is of. The other stations of its workspaces keep a copy,
// brought level (`stationMarks.get`, `stationMarks.put`: follow_marks), the newer of two by its `at`. A picture is not
// kept here, only its address in still.fail cloud's store. A station that only runs tasks keeps none.

///|
/// A station's name and mark: `emoji` and `icon` empty where it has none, `at` when it was set, by the clock of the
/// station it is of.
pub(all) struct MarkRecord {
  name : String
  emoji : String
  icon : String
  at : Int64
}

///|
pub fn MarkRecord::to_json(self : MarkRecord) -> Json {
  {
    "name": Json::string(self.name),
    "emoji": Json::string(self.emoji),
    "icon": Json::string(self.icon),
    "at": int_json(self.at),
  }
}

///|
fn hex64(s : String) -> Bool {
  s.length() == 64 &&
  s.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
/// A name as still.fail cloud takes one: trimmed, spaces made one, 1 to 80 long.
pub fn mark_name(raw : Json?) -> String? {
  guard raw is Some(String(s)) else { return None }
  let t = js_trim(s)
  let b = StringBuilder()
  let mut space = false
  for c in t {
    if js_space(c) {
      space = true
    } else {
      if space {
        b.write_char(' ')
        space = false
      }
      b.write_char(c)
    }
  }
  let clean = b.to_string()
  if clean != "" && clean.length() <= 80 {
    Some(clean)
  } else {
    None
  }
}

///|
fn pictographic_at(c : Int) -> Bool {
  let n = pictographic.length() / 2
  let mut lo = 0
  let mut hi = n - 1
  while lo <= hi {
    let mid = (lo + hi) / 2
    if c < pictographic[mid * 2] {
      hi = mid - 1
    } else if c > pictographic[mid * 2 + 1] {
      lo = mid + 1
    } else {
      return true
    }
  }
  false
}

///|
/// An emoji as the cloud takes one: the first grapheme of what was given, one that is an emoji; "" for none.
pub fn mark_emoji(raw : Json?) -> String? {
  let s = match raw {
    Some(String("")) | Some(Null) => return Some("")
    Some(String(s)) => s
    _ => return None
  }
  let t = js_trim(s)
  if t == "" {
    return None
  }
  let end = @text.next_grapheme(t, 0)
  let first = t.unsafe_substring(start=0, end~)
  if first.length() <= 32 && first.iter().any(c => pictographic_at(c.to_int())) {
    Some(first)
  } else {
    None
  }
}

///|
fn glyph_icon(s : String) -> Bool {
  // ^glyph:[a-z0-9-]{1,40}(:[a-z]{1,16})?$
  guard s.has_prefix("glyph:") else { return false }
  let rest = s.unsafe_substring(start=6, end=s.length())
  let parts = rest.split(":").map(v => v.to_owned()).collect()
  if parts.length() < 1 || parts.length() > 2 {
    return false
  }
  let name = parts[0]
  if name.length() < 1 ||
    name.length() > 40 ||
    !name.iter().all(c => (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') {
    return false
  }
  if parts.length() == 2 {
    let colour = parts[1]
    if colour.length() < 1 ||
      colour.length() > 16 ||
      !colour.iter().all(c => c >= 'a' && c <= 'z') {
      return false
    }
  }
  true
}

///|
fn icon_path(p : String) -> Bool {
  // ^/v1/icons/[0-9a-f]{32}\.(png|webp|jpeg|gif)$
  guard p.has_prefix("/v1/icons/") else { return false }
  let rest = p.unsafe_substring(start=10, end=p.length())
  if rest.length() < 33 {
    return false
  }
  let hash = rest.unsafe_substring(start=0, end=32)
  if !hash.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
    return false
  }
  let ext = rest.unsafe_substring(start=32, end=rest.length())
  ext == ".png" || ext == ".webp" || ext == ".jpeg" || ext == ".gif"
}

///|
/// An icon as the cloud takes one: one of the app's glyphs in a colour, or the address of a picture put up in a
/// still.fail cloud's store; "" for none. Never a picture's bytes.
pub fn mark_icon(raw : Json?) -> String? {
  let s = match raw {
    Some(String("")) | Some(Null) => return Some("")
    Some(String(s)) => s
    _ => return None
  }
  if glyph_icon(s) {
    return Some(s)
  }
  if s.length() > 300 {
    return None
  }
  guard clean_http_url(s, false) is Some(u) else { return None }
  if icon_path(u.path) {
    Some(u.href())
  } else {
    None
  }
}

///|
/// A record as a file or a peer says it; None when it is none.
pub fn mark_of(raw : Json?) -> MarkRecord? {
  guard raw is Some(Object(m)) else { return None }
  guard safe_int(m.get("at")) is Some(at) && at > 0L else { return None }
  let or_empty = (j : Json?) => match j {
    None | Some(Null) => Some(Json::string(""))
    other => other
  }
  match
    (
      mark_name(m.get("name")),
      mark_emoji(or_empty(m.get("emoji"))),
      mark_icon(or_empty(m.get("icon"))),
    ) {
    (Some(name), Some(emoji), Some(icon)) => Some({ name, emoji, icon, at })
    _ => None
  }
}

///|
/// Why a change of a station's mark is refused.
pub(all) suberror MarkRefusal {
  MarkRefusal(String)
}

///|
pub impl Show for MarkRefusal with output(self, logger) {
  match self {
    MarkRefusal(m) => logger.write_string(m)
  }
}

///|
pub struct StationMarks {
  cloud : CloudView
  priv store : Kept
  priv now : () -> Int64
  priv kept : Map[String, MarkRecord]
  priv told : Told[String]
}

///|
pub fn StationMarks::new(
  cloud : CloudView,
  store : Kept,
  now : () -> Int64,
) -> StationMarks {
  {
    cloud,
    store,
    now,
    kept: load_kept(store, (station, raw) => if hex64(station) { mark_of(Some(raw)) } else { None }),
    told: Told::new(),
  }
}

///|
/// This station's id; "" before it is enrolled.
pub fn StationMarks::me(self : StationMarks) -> String {
  (self.cloud.station)().unwrap_or("")
}

///|
pub fn StationMarks::record(self : StationMarks, station : String) -> MarkRecord? {
  self.kept.get(station)
}

///|
/// The stations of `ws` this station knows (its roster's whole stations, itself among them).
pub fn StationMarks::stations_of(self : StationMarks, ws : String) -> Array[String] {
  guard (self.cloud.membership)(ws) is Some(m) else { return [] }
  let ids = m.peers.filter_map(p => match peer_id(p) {
    Some(id) if hex64(id) => Some(id)
    _ => None
  })
  let me = self.me()
  if me != "" && !ids.contains(me) {
    [me, ..ids]
  } else {
    ids
  }
}

///|
/// The records this station keeps of `ws`'s stations, by id, in its roster's order.
pub fn StationMarks::of(self : StationMarks, ws : String) -> Array[(String, MarkRecord)] {
  let out = []
  let seen : Map[String, Bool] = Map([])
  for id in self.stations_of(ws) {
    if seen.contains(id) {
      continue
    }
    seen[id] = true
    if self.kept.get(id) is Some(r) {
      out.push((id, r))
    }
  }
  out
}

///|
pub fn marks_json(marks : Array[(String, MarkRecord)]) -> Json {
  let m : Map[String, Json] = Map([])
  for p in marks {
    m[p.0] = p.1.to_json()
  }
  Json::object(m)
}

///|
/// A peer's record of `station`, kept when it is newer than this station's; whether it was.
pub fn StationMarks::take(
  self : StationMarks,
  station : String,
  record : MarkRecord,
) -> Bool {
  match self.kept.get(station) {
    Some(mine) if record.at <= mine.at => false
    _ => {
      self.keep(station, record)
      true
    }
  }
}

///|
/// This station's own name and mark changed: what is given set (None: as it was), the rest as it was (`was`: what
/// still.fail cloud lists where this station keeps none yet). Made the newest, whatever this machine's clock says.
pub fn StationMarks::change(
  self : StationMarks,
  name? : Json?,
  emoji? : Json?,
  icon? : Json?,
  was : (String, String, String),
) -> MarkRecord raise MarkRefusal {
  let me = self.me()
  if me == "" {
    raise MarkRefusal("this station is not enrolled")
  }
  let base = match self.kept.get(me) {
    Some(r) => r
    None => { name: was.0, emoji: was.1, icon: was.2, at: 0L }
  }
  let name = match name {
    None => Some(base.name)
    Some(n) => mark_name(n)
  }
  guard name is Some(name) else { raise MarkRefusal("name: 1 to 80 characters") }
  let emoji = match emoji {
    None => Some(base.emoji)
    Some(e) => mark_emoji(e)
  }
  guard emoji is Some(emoji) else {
    raise MarkRefusal("emoji: one emoji, or empty for none")
  }
  let icon = match icon {
    None => Some(base.icon)
    Some(i) => mark_icon(i)
  }
  guard icon is Some(icon) else {
    raise MarkRefusal(
      "icon: glyph:<name>[:<colour>], a picture's address in still.fail cloud (/v1/icons/…), or empty for none",
    )
  }
  let at = next_at(self.now, base.at)
  let record = { name, emoji, icon, at }
  self.keep(me, record)
  record
}

///|
fn StationMarks::keep(self : StationMarks, station : String, record : MarkRecord) -> Unit {
  self.kept[station] = record
  save_kept(self.store, self.kept, r => r.to_json())
  self.told.tell(station)
}

///|
pub fn StationMarks::listen(self : StationMarks, f : (String) -> Unit) -> () -> Unit {
  self.told.add(f)
}

// ── between the workspace's stations ──

///|
/// A peer's `stationMarks.*` request, in the workspace it was asked in: only records of that workspace's stations are
/// given or taken.
pub fn answer_marks(
  marks : StationMarks,
  request : Json,
  ws : String,
) -> Json raise NetError {
  match text_of(field(request, "method")) {
    Some("stationMarks.get") => { "marks": marks_json(marks.of(ws)) }
    Some("stationMarks.put") => {
      let ids = marks.stations_of(ws)
      let taken = []
      match field(request, "marks") {
        Some(Object(given)) =>
          for station, raw in given {
            guard mark_of(Some(raw)) is Some(record) else {
              raise NetError("a malformed mark")
            }
            if ids.contains(station) && marks.take(station, record) {
              taken.push(Json::string(station))
            }
          }
        _ => ()
      }
      { "taken": Json::array(taken) }
    }
    _ => raise NetError("unknown stationMarks method")
  }
}

///|
/// Brings one peer and this station level in `ws`: each station's newer record kept by both.
fn level_marks(
  marks : StationMarks,
  call : PeerCall,
  peer : String,
  ws : String,
  home : Bool,
  done : (Result[Unit, String]) -> Unit,
) -> Unit {
  let asked = if home { None } else { Some(ws) }
  (call.call)(peer, asked, { "method": "stationMarks.get" }, got => match got {
    Err(e) => done(Err(e))
    Ok(got) => {
      let theirs : Map[String, MarkRecord] = Map([])
      match field(got, "marks") {
        Some(Object(given)) =>
          for id, raw in given {
            if mark_of(Some(raw)) is Some(r) {
              theirs[id] = r
            }
          }
        _ => ()
      }
      let ids = marks.stations_of(ws)
      for id, r in theirs {
        if ids.contains(id) {
          ignore(marks.take(id, r))
        }
      }
      let give = marks
        .of(ws)
        .filter(p => match theirs.get(p.0) {
          None => true
          Some(t) => p.1.at > t.at
        })
      if give.length() > 0 {
        (call.call)(
          peer,
          asked,
          { "method": "stationMarks.put", "marks": marks_json(give) },
          put => match put {
            Err(e) => done(Err(e))
            Ok(_) => done(Ok(()))
          },
        )
      } else {
        done(Ok(()))
      }
    }
  })
}

///|
/// What of `ws`'s records a peer was brought level with, as a word that changes when any of them does.
fn word_of(marks : StationMarks, ws : String) -> String {
  Json::array(
    marks.of(ws).map(p => Json::array([Json::string(p.0), int_json(p.1.at)])),
  ).stringify()
}

///|
/// Whenever a station's record changes here, or a roster comes, each station of its workspaces is brought level with
/// this one; one that could not be is tried again, sooner at first, until it is. What it returns stops it.
pub fn follow_marks(
  marks : StationMarks,
  call : PeerCall,
  timers : After,
  log? : (String) -> Unit = _ => (),
) -> () -> Unit {
  follow_peers(
    marks.cloud,
    timers,
    "marks",
    true,
    false,
    ws => word_of(marks, ws),
    (peer, ws, home, done) => level_marks(marks, call, peer, ws, home, done),
    f => marks.listen(_ => f()),
    log,
  )
}

///|
/// Tells each change of a station's record to the devices of every workspace it is in here (`stationMarks`).
pub fn tell_marks(marks : StationMarks, tell : Tell) -> () -> Unit {
  marks.listen(station => for m in (marks.cloud.memberships)() {
    if marks.stations_of(m.workspace).contains(station) {
      (tell.tell)(
        "stationMarks",
        { "workspace": Json::string(m.workspace) },
        "stationMarks\u{0}\{m.workspace}",
        m.workspace,
      )
    }
  })
}
