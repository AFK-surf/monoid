// Storms, line for line as station/test/storms.test.ts holds src/mesh/storms.ts: each second a `look()` of the test's
// on a clock it moves, connections whose counts it moves on.

///|
/// A connection whose counts the test moves on; `closed` what closed it (code, reason).
priv struct Fake {
  conn : @door.Connection
  closed : Ref[(Int, String)?]
  counts : Map[String, Double]
}

///|
fn fake(with_packets? : Bool = true) -> Fake {
  let counts : Map[String, Double] = { "rxBytes": 0.0, "txBytes": 0.0 }
  if with_packets {
    for k in counts_named {
      counts[k] = 0.0
    }
  }
  let closed : Ref[(Int, String)?] = Ref(None)
  let conn : @door.Connection = {
    remote_id: () => "ab".repeat(32),
    alpn: () => "",
    via: () => None,
    paths: Some(() => [
      {
        selected: true,
        relay: None,
        ip: Some("192.168.50.68:43112"),
        rtt_ms: Some(9.0),
        tx_packets: 0.0,
        lost_packets: 0.0,
      },
    ]),
    accept_bi: async fn() -> @door.Stream? { None },
    open_bi: async fn() -> @door.Stream { raise @door.DoorError("none") },
    answers: None,
    stats: Some(() => Map::from_iter(counts.iter())),
    close: (code, reason) => closed.val = Some((code, reason)),
    is_closed: () => closed.val is Some(_),
    closed: async fn() -> String { "" },
    close_reason: None,
    handed: None,
  }
  { conn, closed, counts }
}

///|
let counts_named : Array[String] = [
  "rxPackets", "txPackets", "rxPings", "txPings", "rxAckRequests", "txAckRequests",
  "rxAcks", "txAcks", "rxData", "txData",
]

///|
/// One second's traffic: `rx` packets in (pings and ACK requests), `tx` out (ACKs), `data` frames of data.
fn Fake::second(self : Fake, rx : Int, tx : Int, data? : Int = 0) -> Unit {
  guard self.counts.contains("rxPackets") else { return }
  let add = (k : String, n : Int) => self.counts[k] = self.counts.get(k).unwrap_or(0.0) +
    n.to_double()
  add("rxPackets", rx)
  add("txPackets", tx)
  add("rxPings", rx)
  add("rxAckRequests", rx)
  add("txAcks", tx)
  add("rxData", data)
}

///|
/// What the mesh said (level, words, fields), from the door's log.
fn logged() -> Array[(String, String, Json)] {
  let lines = []
  @door.set_log((level, _part, words, with_) => lines.push((level, words, with_)))
  lines
}

///|
fn said(lines : Array[(String, String, Json)], words : String) -> Int {
  lines.filter(l => l.1.contains(words)).length()
}

///|
fn storm_field(line : (String, String, Json), k : String) -> Json? {
  match line.2 {
    Object(m) => m.get(k)
    _ => None
  }
}

///|
test "a connection trading only empty packets, thousands a second, is said once and closed after storm_seconds" {
  let now = Ref(1_000_000L)
  let storms = Storms::new(() => now.val)
  let c = fake()
  storms.watch(c.conn)
  let lines = logged()
  for s = 1; s < storm_seconds; s = s + 1 {
    c.second(32_000, 16_000)
    now.val += 1000L
    storms.look()
    assert_true(c.closed.val is None, msg="still open after \{s} s")
  }
  let storming = lines.filter(l => l.1.contains("is storming"))
  assert_eq(storming.length(), 1)
  assert_eq(storming[0].0, "warn")
  assert_eq(storm_field(storming[0], "rxPackets"), Some(Json::number(32_000.0)))
  assert_eq(storm_field(storming[0], "txAcks"), Some(Json::number(16_000.0)))
  assert_eq(storm_field(storming[0], "device"), Some(Json::string("abababababab")))
  assert_eq(
    storm_field(storming[0], "paths"),
    Some(Json::string("*192.168.50.68:43112 9ms")),
  )
  c.second(32_000, 16_000)
  now.val += 1000L
  storms.look()
  assert_eq(c.closed.val, Some((storm_code, "storm")))
  assert_eq(storm_code, 5)
  assert_eq(said(lines, "storming connection is closed"), 1)
  assert_eq(storms.size(), 0)
  // Closed: no longer looked at.
  c.second(32_000, 16_000)
  now.val += 1000L
  storms.look()
  assert_eq(said(lines, "is storming"), 1)
  assert_eq(said(lines, "storming connection is closed"), 1)
  @door.set_log((_, _, _, _) => ())
}

///|
test "a busy connection carrying data, a short burst, and a connection without packet counts are left alone" {
  let now = Ref(1_000_000L)
  let storms = Storms::new(() => now.val)
  let busy = fake()
  let burst = fake()
  let old = fake(with_packets=false)
  for c in [busy, burst, old] {
    storms.watch(c.conn)
  }
  // (one counting no packets is never looked at)
  assert_eq(storms.size(), 2)
  let lines = logged()
  for s = 0; s < storm_seconds * 3; s = s + 1 {
    // A screen's frames or a download: thousands of packets, many carrying data.
    busy.second(5000, 2500, data=4000)
    // Empty packets for a few seconds at a time, then quiet: never long enough.
    if s % 8 < storm_seconds / 2 {
      burst.second(5000, 2500)
    } else {
      burst.second(10, 5, data=2)
    }
    now.val += 1000L
    storms.look()
  }
  assert_true(busy.closed.val is None)
  assert_true(burst.closed.val is None)
  assert_true(old.closed.val is None)
  assert_eq(said(lines, "is storming"), 4)
  assert_true(said(lines, "storm is over") >= 1)
  assert_eq(said(lines, "storming connection is closed"), 0)
  assert_eq(storms.size(), 2)
  @door.set_log((_, _, _, _) => ())
}

///|
test "a connection is storming only while hardly any of its packets carry data" {
  let now = Ref(1_000_000L)
  let storms = Storms::new(() => now.val)
  // 1000 a second with one in 50 carrying data is still a storm; one more data frame is not.
  let edge = fake()
  let over = fake()
  storms.watch(edge.conn)
  storms.watch(over.conn)
  let lines = logged()
  for _ in 0..<storm_seconds {
    edge.second(1000, 0, data=20)
    over.second(1000, 0, data=21)
    now.val += 1000L
    storms.look()
  }
  assert_eq(edge.closed.val, Some((5, "storm")))
  assert_true(over.closed.val is None)
  // Under storm_packets a second: never one.
  let quiet = fake()
  storms.watch(quiet.conn)
  for _ in 0..<(storm_seconds * 2) {
    quiet.second(999, 999)
    now.val += 1000L
    storms.look()
  }
  assert_true(quiet.closed.val is None)
  assert_eq(said(lines, "is storming"), 1)
  @door.set_log((_, _, _, _) => ())
}
