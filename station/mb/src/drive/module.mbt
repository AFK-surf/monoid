// What another station of the workspace reads of this one's drive with a grant of its own (module.ts: `drive.walk`,
// `drive.part`, `drive.release` on the bus), and another station's drive as a transfer's source.

///|
/// A refusal over the station transport (mesh/bus.ts `Refused`): the other station is told why.
pub(all) suberror Refused {
  Refused(String)
}

///|
pub impl Show for Refused with output(self, logger) {
  let Refused(m) = self
  logger.write_string(m)
}

///|
/// An answer over the station transport (bus.ts): its JSON, and the bytes that follow it on its stream (`withBytes`),
/// read a piece at a time until None, let go with `stop`.
pub(all) struct Answer {
  json : JV
  bytes : (async () -> Bytes?, async () -> Unit)?
}

///|
/// How much of a file is read at once as it is sent (module.ts PIECE).
let piece : Double = 1048576.0

///|
/// What a request reads at a time from a station from before (jobs/remote.ts CHUNK).
pub let chunk : Double = 262144.0

///|
/// The drive as a workspace has it (module.ts `scoped`).
fn scoped_for(drive : Drive, g : JV) -> Drive {
  if jbool(g, "home") == Some(true) {
    drive
  } else {
    drive.scoped(jstr(g, "workspace").unwrap_or(""))
  }
}

///|
/// Buffer's toString("base64").
pub fn base64(b : Bytes) -> String {
  @codec.base64_encode(b[:])
}

///|
fn granted_names(request : JV, g : JV) -> Array[String] {
  let given = grant_names(g)
  match oget(request, "names") {
    Some(Arr(a)) =>
      a.filter_map(n => match n {
        Str(u) if given.contains(@jsjson.sanitize_str(u)) => Some(@jsjson.sanitize_str(u))
        _ => None
      })
    _ => given
  }
}

///|
/// module.ts `driveForPeer`: what another station reads of this one's drive with a grant of this one's.
pub fn drive_for_peer(
  drive : Drive,
  key : Bytes,
  request : JV,
  workspace : String?,
  now : Double,
) -> Answer raise Refused {
  try {
    let g = verify(key, oget(request, "grant"), workspace, now)
    let d = scoped_for(drive, g)
    let root = jstr(g, "root").unwrap_or("")
    let gpath = jstr(g, "path").unwrap_or("")
    let anywhere = jbool(g, "anywhere") == Some(true)
    match ostr(request, "method") {
      Some("drive.walk") => {
        let names = match oget(request, "names") {
          Some(Arr(_)) => granted_names(request, g)
          _ => grant_names(g)
        }
        { json: Obj([(ju("items"), Arr(walk_drive(d, root, gpath, names, anywhere)))]), bytes: None }
      }
      Some("drive.part") => {
        let path = ostr(request, "path").unwrap_or("")
        let offset = match oget(request, "offset") {
          Some(Num(n)) if safe_integer(n) && n >= 0.0 => n
          _ => -1.0
        }
        if !covers(g, path) || offset < 0.0 {
          raise drive_error("permission", "that is not what was granted")
        }
        let at = join2(gpath, path)
        let whole = oget(request, "whole") is Some(Bool(true))
        let got = d.read(root, at, offset, if whole { piece } else { chunk }, anywhere)
        if !whole {
          return {
            json: Obj([
              (ju("data"), jvs(base64(got.bytes))),
              (ju("size"), Num(got.total)),
              (ju("mtime"), Num(got.mtime)),
            ]),
            bytes: None,
          }
        }
        // The rest as it is read, until it changes.
        let mut first = true
        let mut next = offset + got.bytes.length().to_double()
        let mut over = false
        let more = async fn() -> Bytes? {
          if over {
            return None
          }
          if first {
            first = false
            return Some(got.bytes)
          }
          if next >= got.total {
            over = true
            return None
          }
          let m = d.read(root, at, next, piece, anywhere)
          if m.mtime != got.mtime || m.total != got.total || m.bytes.length() == 0 {
            over = true
            return None
          }
          next = next + m.bytes.length().to_double()
          Some(m.bytes)
        }
        let stop = async fn() { over = true }
        {
          json: Obj([(ju("size"), Num(got.total)), (ju("mtime"), Num(got.mtime))]),
          bytes: Some((more, stop)),
        }
      }
      Some("drive.release") => {
        if jbool(g, "move") != Some(true) {
          raise drive_error("permission", "that grant copies, and does not move")
        }
        let names = match oget(request, "names") {
          Some(Arr(_)) => granted_names(request, g)
          _ => []
        }
        for name in names {
          remove_or_trash(d, root, join2(gpath, name), anywhere)
        }
        { json: Obj([]), bytes: None }
      }
      m => {
        let said = match m {
          Some(s) => s
          None =>
            match oget(request, "method") {
              None => "undefined"
              Some(Null) => "null"
              Some(Num(n)) => js_number(n)
              Some(Bool(b)) => b.to_string()
              _ => "[object Object]"
            }
        }
        raise drive_error("invalid_request", "unknown method \{said}")
      }
    }
  } catch {
    DriveError(d) => raise Refused("\{d.code}: \{d.message}")
    e => raise Refused(message_of(e))
  }
}

///|
/// The file coming now (module.ts `coming`).
priv struct Coming {
  path : String
  mut at : Double
  size : Double
  mtime : Double
  next : async () -> Bytes?
  stop : async () -> Unit
  mut carry : Bytes
}

///|
/// module.ts `peerSource`: another station's drive as a transfer's source, read over the station transport with its
/// grant, a file whole from where it is first read.
pub fn peer_source(ask : async (String, JV) -> Answer, t : JV) -> Source {
  let from = oget(t, "from").unwrap_or(Null)
  let station = ostr(from, "station").unwrap_or("")
  let base = () => {
    let o : JV = Obj([])
    oset(o, "workspace", oget(t, "workspace").unwrap_or(Null))
    match oget(from, "grant") {
      Some(g) => oset(o, "grant", g)
      None => ()
    }
    o
  }
  let coming : Ref[Coming?] = { val: None }
  let stop = async fn() {
    let was = coming.val
    coming.val = None
    if was is Some(c) {
      (c.stop)()
    }
  }
  async fn read(path : String, offset : Double, again : Bool) -> (Bytes, Double, Double) {
    match coming.val {
      Some(c) if c.path != path || c.at != offset => stop()
      _ => ()
    }
    if coming.val is None {
      let q = base()
      oset(q, "method", jvs("drive.part"))
      oset(q, "path", jvs(path))
      oset(q, "offset", Num(offset))
      oset(q, "whole", Bool(true))
      let got = ask(station, q)
      let size = match oget(got.json, "size") {
        Some(Num(n)) => n
        _ => raise Failure("\{station} answered no part of \{path}")
      }
      let mtime = match oget(got.json, "mtime") {
        Some(Num(n)) => n
        _ => 0.0
      }
      match got.bytes {
        None =>
          match oget(got.json, "data") {
            Some(Str(u)) => return (from_base64(@jsjson.sanitize_str(u)), size, mtime)
            _ => raise Failure("\{station} answered no part of \{path}")
          }
        Some((next, stop_bytes)) =>
          coming.val = Some({
            path,
            at: offset,
            size,
            mtime,
            next,
            stop: stop_bytes,
            carry: b"",
          })
      }
    }
    let c = coming.val.unwrap()
    let parts = @buffer.new()
    parts.write_bytes(c.carry)
    let mut n = c.carry.length().to_double()
    let mut ended_ = false
    while n < chunk && c.at + n < c.size {
      let next = (c.next)() catch {
        e => {
          coming.val = None
          raise e
        }
      }
      match next {
        None => {
          ended_ = true
          break
        }
        Some(b) => {
          parts.write_bytes(b)
          n = n + b.length().to_double()
        }
      }
    }
    let all = parts.to_bytes()
    let take = if all.length() > chunk.to_int() { chunk.to_int() } else { all.length() }
    let bytes = all[0:take].to_bytes()
    c.carry = all[take:].to_bytes()
    c.at = c.at + take.to_double()
    if ended_ || c.at >= c.size {
      coming.val = None
    }
    if bytes.length() == 0 && c.at < c.size && again {
      return read(path, offset, false)
    }
    (bytes, c.size, c.mtime)
  }

  {
    station: Some(station),
    part: chunk,
    walk: async fn(names) {
      let q = base()
      oset(q, "method", jvs("drive.walk"))
      oset(q, "names", Arr(names.map(jvs)))
      let got = ask(station, q)
      match oget(got.json, "items") {
        Some(Arr(a)) => a
        _ => []
      }
    },
    read: async fn(path, offset, _length) { read(path, offset, true) },
    release: async fn(names) {
      stop()
      let q = base()
      oset(q, "method", jvs("drive.release"))
      oset(q, "names", Arr(names.map(jvs)))
      ask(station, q) |> ignore
    },
  }
}
