// ops/forewarn.ts, line for line: what runs out on the station's machine said before it does (the data directory's
// disk, the database's log, the process's descriptors, a relay's conflict over this station's key), each as it starts
// and again every `forewarn_again_ms` while it lasts (a relay's conflict once, until it ends).

///|
let forewarn_mib : Double = 1048576.0

///|
pub let forewarn_low_disk_bytes : Double = 2048.0 * forewarn_mib

///|
pub let forewarn_low_disk_share : Double = 0.05

///|
pub let forewarn_large_wal_bytes : Double = 256.0 * forewarn_mib

///|
pub let forewarn_many_fds : Int = 2048

///|
pub let forewarn_again_ms : Double = 600000.0

///|
/// forewarn.ts `Look`: what is looked at, in bytes (None where the system does not say).
pub(all) struct ForewarnLook {
  disk_free : Double?
  disk_total : Double?
  wal_bytes : Double
  open_fds : Int?
  rss : Double?
  relay_conflict : Bool
}

///|
/// forewarn.ts `Warning`: a WARN line's part, words and fields.
pub(all) struct ForewarnSaid {
  at : String
  message : String
  fields : Json
}

///|
/// forewarn.ts `mb`: bytes as whole MiB.
pub fn forewarn_mb(bytes : Double) -> Double {
  js_round(bytes / forewarn_mib)
}

///|
/// forewarn.ts `Forewarn`: which of what is looked at holds, each with when it was last said.
pub struct Forewarn {
  said : Map[String, Double]
}

///|
pub fn Forewarn::new() -> Forewarn {
  { said: Map([]) }
}

///|
/// forewarn.ts `look`: what to say of `look` at `now` (ms).
pub fn Forewarn::look(self : Forewarn, look : ForewarnLook, now : Double) -> Array[ForewarnSaid] {
  let out = []
  fn held(kind : String, on : Bool, again : Bool, said : () -> ForewarnSaid) -> Unit {
    if !on {
      self.said.remove(kind)
      return
    }
    match self.said.get(kind) {
      Some(at) if !again || now - at < forewarn_again_ms => return
      _ => ()
    }
    self.said[kind] = now
    out.push(said())
  }
  let low_disk = match (look.disk_free, look.disk_total) {
    (Some(free), Some(total)) =>
      total > 0.0 && (free < forewarn_low_disk_bytes || free < total * forewarn_low_disk_share)
    _ => false
  }
  held("disk", low_disk, true, () => {
    let free = look.disk_free.unwrap_or(0.0)
    let total = look.disk_total.unwrap_or(1.0)
    {
      at: "station",
      message: "low disk space on data directory",
      fields: {
        "diskFreeMb": jn(forewarn_mb(free)),
        "diskTotalMb": jn(forewarn_mb(total)),
        "freePct": jn(js_round(free / total * 1000.0) / 10.0),
      },
    }
  })
  held("wal", look.wal_bytes > forewarn_large_wal_bytes, true, () => {
    at: "store",
    message: "database WAL file is large",
    fields: { "walMb": jn(forewarn_mb(look.wal_bytes)) },
  })
  let many_fds = match look.open_fds {
    Some(n) => n >= forewarn_many_fds
    None => false
  }
  held("fds", many_fds, true, () => {
    let fields : Map[String, Json] = { "openFds": ji(look.open_fds.unwrap_or(0)) }
    if look.rss is Some(rss) {
      fields["rssMb"] = jn(forewarn_mb(rss))
    }
    { at: "station", message: "high open file descriptor count", fields: Json::object(fields) }
  })
  held("relay", look.relay_conflict, false, () => {
    at: "mesh",
    message: "relay reports another endpoint with this station key",
    fields: Json::object({}),
  })
  out
}
