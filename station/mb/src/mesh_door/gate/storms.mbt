// Connections that only trade packets that carry nothing (station/src/mesh/storms.ts): looked at each second, one
// receiving STORM_PACKETS a second or more, hardly any carrying data, is a storm, said once as it begins and closed once
// it has gone on STORM_SECONDS.

///|
pub let storm_packets : Int = 1000

///|
let data_one_in : Int = 50

///|
pub let storm_seconds : Int = 10

///|
pub let storm_code : Int = 5

///|
let counts : Array[String] = [
  "rxPackets", "txPackets", "rxPings", "txPings", "rxAckRequests", "txAckRequests",
  "rxAcks", "txAcks", "rxData", "txData",
]

///|
struct Watched {
  conn : @door.Connection
  mut last : Map[String, Double]
  mut at : Int64
  mut since : Int64?
  mut seconds : Double
}

///|
pub struct Storms {
  now : () -> Int64
  watched : Array[Watched]
}

///|
pub fn Storms::new(now : () -> Int64) -> Storms {
  { now, watched: [] }
}

///|
/// Looks at every connection each second, until the fiber it runs in is let go.
pub async fn Storms::start(self : Storms) -> Unit {
  while true {
    @effect.sleep(1000)
    self.look()
  }
}

///|
/// `conn` is looked at from now on, while it is open; not when it counts no packets.
pub fn Storms::watch(self : Storms, conn : @door.Connection) -> Unit {
  guard conn.stats is Some(stats) else { return }
  let now = stats()
  guard now.contains("rxPackets") else { return }
  self.watched.push({ conn, last: now, at: (self.now)(), since: None, seconds: 0.0 })
}

///|
/// JavaScript's Math.round.
fn js_round(x : Double) -> Double {
  (x + 0.5).floor()
}

///|
/// How many connections are looked at.
pub fn Storms::size(self : Storms) -> Int {
  self.watched.length()
}

///|
/// One look at each connection: how much came on it since the last.
pub fn Storms::look(self : Storms) -> Unit {
  let at = (self.now)()
  let keep = []
  for w in self.watched {
    if (w.conn.is_closed)() {
      continue
    }
    let now = (w.conn.stats.unwrap())()
    let secs = (at - w.at).to_double() / 1000.0
    let seconds = if secs < 1.0 { 1.0 } else { secs }
    let rate : Map[String, Double] = Map([])
    for k in counts {
      rate[k] = js_round((now.get(k).unwrap_or(0.0) - w.last.get(k).unwrap_or(0.0)) / seconds)
    }
    w.last = now
    w.at = at
    let r = (k : String) => rate.get(k).unwrap_or(0.0)
    let storming = r("rxPackets") >= storm_packets.to_double() &&
      (r("rxData") + r("txData")) * data_one_in.to_double() <= r("rxPackets")
    let id = (w.conn.remote_id)()
    let device = if id.length() > 12 { id.clamped_view(end=12).to_owned() } else { id }
    if !storming {
      if w.since is Some(_) {
        @door.log("info", "mesh", "a connection's storm is over", { "device": Json::string(device), "seconds": Json::number(w.seconds) })
      }
      w.since = None
      w.seconds = 0.0
      keep.push(w)
      continue
    }
    w.seconds += seconds
    if w.since is None {
      w.since = Some(at)
      let m : Map[String, Json] = { "device": Json::string(device) }
      for k in counts {
        m[k] = Json::number(r(k))
      }
      let paths = match w.conn.paths {
        Some(p) =>
          p()
          .map(p => {
            let rtt = match p.rtt_ms { Some(ms) => "\{js_round(ms).to_int64()}ms"; None => "?" }
            "\{if p.selected { "*" } else { "" }}\{either(p.ip, p.relay).unwrap_or("?")} \{rtt}"
          })
          .join("; ")
        None => ""
      }
      m["paths"] = Json::string(paths)
      @door.log("warn", "mesh", "a connection is storming: packets that carry nothing, thousands a second", Json::object(m))
    }
    if w.seconds >= storm_seconds.to_double() {
      @door.log("warn", "mesh", "a storming connection is closed", { "device": Json::string(device), "seconds": Json::number(js_round(w.seconds)) })
      (w.conn.close)(storm_code, "storm")
      continue
    }
    keep.push(w)
  }
  self.watched.clear()
  for w in keep {
    self.watched.push(w)
  }
}
