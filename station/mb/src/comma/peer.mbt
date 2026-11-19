// The workspace's statistics as a Comma connect sends them (station/src/comma/peer.ts): this station's, read here, and
// each other station's of the workspace, read of it over the mesh (`outflow.read`, the name stations of every version
// answer), and how a station answers another's read.

///|
/// What another station of the workspace asks of this one's statistics.
pub let read_method : String = "outflow.read"

///|
let ops : Array[String] = ["outflowUsage", "outflowChats", "outflowMessages"]

///|
/// The Router of the Comma connect on another station of the workspace writing in one of this station's chats.
pub let say_method : String = "comma.say"

///|
/// Another station of the workspace telling that one of its chats moved, so a Comma connect rebuilds its Task index soon.
pub let changed_method : String = "comma.changed"

///|
/// An answer of another station's read, at most.
let answer_max : Int = 67108864

///|
/// Chats a read takes at once.
let chats_page : Int = 1000

///|
/// Bound the simultaneous peer reads: each answer can itself be large.
let peer_reads : Int = 2

///|
/// What answers another station's read: its head (`{size}`), its bytes, and the check made again before they leave
/// (the transport writes the head before it pulls the body).
pub(all) struct PeerAnswer {
  head : J
  bytes : Bytes
  check : () -> Unit raise
}

///|
/// `{...v}` of what may be anything: an object's fields, an array's or a string's by their indexes, nothing else's.
fn spread(v : J?) -> Array[(String, J)] {
  match v {
    Some(Obj(entries)) => entries.copy()
    Some(Arr(items)) => items.mapi((i, x) => (i.to_string(), x))
    Some(Str(u)) => Array::makei(u.length(), i => (i.to_string(), Str(u.unsafe_substring(start=i, end=i + 1))))
    _ => []
  }
}

///|
/// What answers another station's `outflow.read`: the read it names of this station's chats of the workspace it asks
/// in, the answer's JSON as the bytes after its head. `version` changes whenever the home workspace changes; `member`
/// refuses a peer no longer authorized in the requested workspace.
pub fn peer_read(
  read : async (String, J, String) -> String,
  home : () -> String?,
  lang : () -> String,
  version : () -> Int,
  member : (String, String) -> Unit raise,
) -> async (String, J, String?) -> PeerAnswer {
  async fn(peer, request, workspace) {
    let op = match prop(Some(request), "op") {
      Some(Str(u)) => u
      _ => ""
    }
    if !ops.contains(op) {
      raise fail_("no such read")
    }
    let workspace = match workspace {
      Some(w) if w != "" => w
      _ => raise fail_("which workspace is not known")
    }
    let original_home = home()
    let original_version = version()
    let check = fn() raise {
      if home() != original_home || version() != original_version {
        raise fail_("the workspace changed while reading")
      }
      member(peer, workspace)
    }
    check()
    let args = match prop(Some(request), "args") {
      Some(Obj(_) | Arr(_)) as a => spread(a)
      _ => []
    }
    let said = lang()
    put_field(args, "lang", jstr(said))
    put_field(
      args,
      "ws",
      jobj([("workspace", jstr(workspace)), ("home", Bool(Some(workspace) == original_home))]),
    )
    let text = read(op, Obj(args), said)
    check()
    let bytes = utf8_of(text)
    { head: jobj([("size", ji(bytes.length()))]), bytes, check }
  }
}

///|
/// The bytes after an answer, pulled a chunk at a time until None, as text (at most ANSWER_MAX).
pub async fn text_of(next : async () -> Bytes?) -> String {
  let chunks = []
  let mut size = 0
  while next() is Some(chunk) {
    size += chunk.length()
    if size > answer_max {
      raise fail_("that station's answer is too long")
    }
    chunks.push(chunk)
  }
  let out = @buffer.new(size_hint=size)
  for c in chunks {
    out.write_bytes(c)
  }
  text_of_utf8(out.to_bytes())
}

///|
/// What a build reads of the workspace's stations.
pub(all) struct WorkspaceReads {
  /// The workspace read and whether it is this station's home one; None before the station is in one.
  of : () -> (String, Bool)?
  /// This station's read: as the reader pool answers it.
  here : async (String, J) -> String
  /// The other stations of the workspace, by id; raises when the roster is not known now.
  others : async () -> Array[String]
  /// Another station's read.
  there : async (String, String, J) -> String
}

///|
/// The workspace as a read names it: `{workspace, home}`.
pub fn ws_j(of : (String, Bool)) -> J {
  jobj([("workspace", jstr(of.0)), ("home", Bool(of.1))])
}

///|
fn nullable_text(v : J?) -> Bool {
  v is Some(Null | Str(_))
}

///|
/// One station's usage and chats of the workspace from `from` until `to`, by `ask`.
async fn station_rows(ask : async (String, J) -> String, from : Double, to : Double) -> (J, Array[J]) {
  let usage = parse_json(
    ask("outflowUsage", jobj([("from", Num(from)), ("to", Num(to)), ("tz", Num(0.0))])),
  )
  // A partial answer must not make this station's previously indexed rows look absent.
  let complete = match prop(Some(usage), "rows") {
    Some(Arr(rows)) =>
      rows.iter().all(row => {
        let r = Some(row)
        prop(r, "day") is Some(Str(_)) &&
        prop(r, "session") is Some(Str(_)) &&
        prop(r, "runtime") is Some(Str(_)) &&
        nullable_text(prop(r, "person")) &&
        nullable_text(prop(r, "account")) &&
        nullable_text(prop(r, "model"))
      })
    _ => false
  }
  if !complete {
    raise fail_("that station's usage answer is incomplete")
  }
  let chats = []
  let mut before : String? = None
  let cursors : Set[String] = Set::new()
  while true {
    let args = jo([
      ("since", Some(Num(from))),
      ("limit", Some(ji(chats_page))),
      ("before", before.map(jstr)),
    ])
    let page = parse_json(ask("outflowChats", args))
    let page_chats = match prop(Some(page), "chats") {
      Some(Arr(items)) if items.iter().all(c => prop(Some(c), "thread") is Some(Num(_))) => items
      _ => raise fail_("that station's chat answer is incomplete")
    }
    chats.append(page_chats)
    // Older stations returned all chats without pagination fields.
    let more = prop(Some(page), "more")
    if more is (None | Some(Bool(false))) {
      break
    }
    let next = match (more, prop(Some(page), "next")) {
      (Some(Bool(true)), Some(Str(u))) if u.length() > 0 && !cursors.contains(u) => u
      _ => raise fail_("that station's chat cursor does not continue")
    }
    cursors.add(next)
    before = Some(next)
  }
  (usage, chats)
}

///|
/// `{...args, ...extra}`.
fn with_fields(args : J, extra : Array[(String, J)]) -> J {
  let out = spread(Some(args))
  for e in extra {
    put_field(out, e.0, e.1)
  }
  Obj(out)
}

///|
/// What a build reads: this station's rows, and each other station's of the workspace that answers.
pub fn workspace_read(w : WorkspaceReads) -> async (Double, Double) -> ReadRows {
  async fn(from, to) {
    let of = (w.of)()
    let ws : Array[(String, J)] = match of {
      None => []
      Some(o) => [("ws", ws_j(o))]
    }
    let (usage, chats) = station_rows(async fn(op, args) { (w.here)(op, with_fields(args, ws)) }, from, to)
    let stations : Array[StationRows] = [{ station: None, usage, chats }]
    let unread = []
    let others = match of {
      None => []
      Some(_) => (w.others)()
    }
    let results : Array[StationRows?] = Array::make(others.length(), None)
    let next = Ref(0)
    let worker = async fn() {
      while true {
        let at = next.val
        next.val += 1
        if at >= others.length() {
          return
        }
        let station = others[at]
        let got = try {
          Some(station_rows(async fn(op, args) { (w.there)(station, op, args) }, from, to))
        } catch {
          // Keep this station's previous rows when it cannot answer.
          _ => None
        }
        match got {
          Some((usage, chats)) => results[at] = Some({ station: Some(station), usage, chats })
          None => ()
        }
      }
    }
    let n = if others.length() < peer_reads { others.length() } else { peer_reads }
    ignore(@effect.all(Array::make(n, worker)))
    // Completion order must not change the order in which the index gives revisions to the rows.
    for i in 0..<others.length() {
      match results[i] {
        Some(r) => stations.push(r)
        None => unread.push(others[i])
      }
    }
    { stations, unread, valid: None }
  }
}
