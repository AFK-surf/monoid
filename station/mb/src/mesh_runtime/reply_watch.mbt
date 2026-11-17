// What the log says of the ways a connection goes by (station/src/mesh/reply-watch.ts): all it has now (`paths_of`),
// and a large reply that was slow to be taken in (`slowly`): once the device has taken all its bytes in, said when that
// took over SLOW_REPLY_MS, with how long it was made in, the way it went and the packets sent on each way meanwhile.

///|
/// A reply this long or longer whose bytes took more than SLOW_REPLY_MS to be taken in whole is said on the log.
pub let slow_reply_bytes : Int = 256 * 1024

///|
pub let slow_reply_ms : Double = 5_000.0

///|
/// One way a connection has now (endpoint.ts `PathInfo`).
pub(all) struct WayPath {
  selected : Bool
  relay : String?
  ip : String?
  rtt_ms : Double?
  tx_packets : Double
  lost_packets : Double
  cwnd : Double?
  congestion_events : Double?
}

///|
/// A way as JSON says it (`{selected, relay?, ip?, rttMs?, txPackets, lostPackets, cwnd?, congestionEvents?}`).
pub fn WayPath::of_json(v : Json) -> WayPath {
  let opt_num = (k : String) => match field(v, k) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
  {
    selected: field(v, "selected") is Some(True),
    relay: str_of(field(v, "relay")),
    ip: str_of(field(v, "ip")),
    rtt_ms: opt_num("rttMs"),
    tx_packets: opt_num("txPackets").unwrap_or(0.0),
    lost_packets: opt_num("lostPackets").unwrap_or(0.0),
    cwnd: opt_num("cwnd"),
    congestion_events: opt_num("congestionEvents"),
  }
}

///|
fn where_(p : WayPath) -> String {
  match (p.relay, p.ip) {
    (Some(r), _) => r
    (None, Some(ip)) => ip
    _ => "?"
  }
}

///|
fn rtt_word(p : WayPath) -> String {
  match p.rtt_ms {
    None => "?"
    Some(ms) => "\{js_num(js_round(ms))}ms"
  }
}

///|
/// Every way a connection has now: `*` the chosen one, its relay or address, round trip, packets sent and lost.
pub fn paths_of(paths : Array[WayPath]) -> String {
  paths
  .map(p => "\{if p.selected { "*" } else { "" }}\{where_(p)} \{rtt_word(p)} \{js_num(p.tx_packets)}/\{js_num(p.lost_packets)}")
  .join(", ")
}

///|
/// The packets sent so far on each of a connection's ways, by a key unique among them (`#n` for its n-th way there).
pub fn sent_on(paths : Array[WayPath]) -> Array[(String, Double)] {
  let seen : Map[String, Int] = Map([])
  paths.map(p => {
    let at = where_(p)
    let n = seen.get(at).unwrap_or(0)
    seen[at] = n + 1
    (if n != 0 { "\{at}#\{n}" } else { at }, p.tx_packets)
  })
}

///|
/// What is said of a reply once its stream told how it ended (`code`: the code it was stopped with, None once all
/// was taken in), `ms` after it began going: None when nothing is (it was stopped, or it was quick enough). `before`:
/// `sent_on` as it began; `paths`, the ways now.
pub fn slow_line(
  before : Array[(String, Double)],
  code : Int?,
  ms : Double,
  paths : Array[WayPath],
  route : () -> String,
  bytes : Double,
  made : Double,
  device : String,
) -> Json? {
  if code is Some(_) || ms < slow_reply_ms {
    return None
  }
  let way = paths.search_by(p => p.selected).map(i => paths[i])
  let after = sent_on(paths)
  let ways = paths.mapi((i, p) => {
    let (key, sent) = after[i]
    let was = match before.search_by(b => b.0 == key) {
      Some(j) => before[j].1
      None => 0.0
    }
    let cwnd = match p.cwnd {
      Some(c) => js_num(c)
      None => "?"
    }
    "\{if p.selected { "*" } else { "" }}\{key} \{rtt_word(p)} +\{js_num(sent - was)}/\{js_num(p.lost_packets)} cwnd=\{cwnd}"
  })
  let opt = (v : Double?) => match v {
    Some(n) => jnum(n)
    None => Json::null()
  }
  Some(
    jobj([
      ("route", jstr(route())),
      ("bytes", jnum(bytes)),
      ("made", jnum(made)),
      ("ms", jnum(ms)),
      ("bytesPerSecond", jnum(js_round(bytes / ms * 1000.0))),
      ("device", jstr(device)),
      ("way", jstr(match way { Some(w) => where_(w); None => "?" })),
      ("rtt", match way { Some({ rtt_ms: Some(r), .. }) => jnum(js_round(r)); _ => Json::null() }),
      ("sent", match way { Some(w) => jnum(w.tx_packets); None => Json::null() }),
      ("lost", match way { Some(w) => jnum(w.lost_packets); None => Json::null() }),
      ("cwnd", match way { Some(w) => opt(w.cwnd); None => Json::null() }),
      ("cuts", match way { Some(w) => opt(w.congestion_events); None => Json::null() }),
      ("ways", jstr(ways.join(", "))),
    ]),
  )
}

///|
/// A large reply's bytes, once the device has taken them all in (`slowly`): said on the log (`said`, "info") when that
/// took over SLOW_REPLY_MS. `now`: the wall clock; `from`: when it began going.
pub async fn slowly(
  stream : @door.Stream,
  paths : () -> Array[WayPath],
  device : String,
  route : () -> String,
  bytes : Double,
  made : Double,
  from : Double,
  now : () -> Double,
  said : (String, String, Json) -> Unit,
) -> Unit {
  let before = sent_on(paths())
  let code = (stream.stopped)() catch { _ => return }
  if slow_line(before, code, now() - from, paths(), route, bytes, made, device) is Some(line) {
    said("info", "a reply went slowly", line)
  }
}
