// How the station's own process is, said in its log as main.ts says it: its statements on the store timed
// (store/timed.ts: one of SLOW_MS or more said, each put down for the heartbeat's window), the loop held (main.ts
// HELD_MS, with the window's statements), what runs out on the machine (ops/forewarn.ts, ops_platform/forewarn.mbt)
// and `memory: now`.

///|
/// store/timed.ts SLOW_MS: a statement on the station's loop taking this long is said.
const SLOW_QUERY_MS : Double = 200.0

///|
/// main.ts HELD_MS: a sample of the loop this late is said.
const HELD_SAID_MS : Double = 1000.0

///|
/// What the loop's statements took since the heartbeat last took them (store/timed.ts `takeQueries`).
priv struct QueryWindow {
  mut longest : Double
  mut ms : Double
  mut calls : Int
}

///|
let query_window : QueryWindow = { longest: 0.0, ms: 0.0, calls: 0 }

///|
/// What the window holds, and the window begun again.
fn take_queries() -> (Double, Double, Int) {
  let taken = (query_window.longest, query_window.ms, query_window.calls)
  query_window.longest = 0.0
  query_window.ms = 0.0
  query_window.calls = 0
  taken
}

///|
/// store/timed.ts `shortSql`: its SQL on one line, cut where it gets long.
fn short_sql(sql : String) -> String {
  let b = StringBuilder()
  let mut space = false
  let mut started = false
  for c in sql {
    if c == ' ' || c == '\n' || c == '\t' || c == '\r' || c == '\u{0b}' || c == '\u{0c}' {
      space = true
    } else {
      if space && started {
        b.write_char(' ')
      }
      space = false
      started = true
      b.write_char(c)
    }
  }
  let one = b.to_string()
  if one.length() > 300 {
    one[:300].to_owned() + "…"
  } else {
    one
  }
}

///|
/// A statement of the station's store as it ran (`@sql.Db::timed`): put down for the window, said where it was slow,
/// with its SQL but never what it was given (someone's words).
fn main_query_said(sql : String, ms : Double, rows : Int?, failed : String?) -> Unit {
  query_window.calls += 1
  query_window.ms += ms
  if ms > query_window.longest {
    query_window.longest = ms
  }
  if ms >= SLOW_QUERY_MS {
    let fields : Map[String, Json] = { "ms": Json::number(ms.round()) }
    if rows is Some(n) {
      fields["rows"] = Json::number(n.to_double())
    }
    if failed is Some(f) {
      fields["failed"] = Json::string(f)
    }
    fields["sql"] = Json::string(short_sql(sql))
    p51_log("WARN", "store", "a slow query on the main thread", fields=Json::object(fields))
  }
}

///|
/// ops/pressure.ts `Pressure`: the machine's counters at one time, the µs some or every task waited, and the stalls.
priv struct Pressure {
  cpu_some : Double
  memory_some : Double
  memory_full : Double
  compact_stalls : Double
  alloc_stalls : Double
}

///|
/// A counter of the kernel's (its decimal digits), none where it is not one.
fn counter(text : String) -> Double? {
  if text.length() == 0 {
    return None
  }
  let mut n = 0.0
  for c in text {
    guard c >= '0' && c <= '9' else { return None }
    n = n * 10.0 + (c.to_int() - '0'.to_int()).to_double()
  }
  Some(n)
}

///|
/// ops/pressure.ts `stallTotal`: `total=` of the `some` or `full` line of a /proc/pressure file (µs).
fn stall_total(text : String, which : String) -> Double? {
  for line in text.split("\n") {
    let line = line.to_owned()
    if line.has_prefix(which + " ") {
      for part in line.split(" ") {
        let part = part.to_owned()
        if part.has_prefix("total=") {
          return counter(part[6:].to_owned())
        }
      }
    }
  }
  None
}

///|
/// ops/pressure.ts `vmStalls`: /proc/vmstat's direct compaction stalls and direct reclaim stalls (`allocstall_*`).
fn vm_stalls(text : String) -> (Double, Double) {
  let mut compact = 0.0
  let mut alloc = 0.0
  for line in text.split("\n") {
    let parts = line.split(" ").map(p => p.to_owned()).collect()
    if parts.length() >= 2 {
      let n = counter(parts[1]).unwrap_or(0.0)
      if parts[0] == "compact_stall" {
        compact = n
      } else if parts[0].has_prefix("allocstall_") {
        alloc += n
      }
    }
  }
  (compact, alloc)
}

///|
/// ops/pressure.ts `pressureNow`: the counters now; none where the system keeps none.
fn pressure_now() -> Pressure? {
  let read = (p : String) => (try { Some(@utf8.decode_lossy(@drive.read_all(p))) } catch { _ => None })
  guard read("/proc/pressure/cpu") is Some(cpu) &&
    read("/proc/pressure/memory") is Some(memory) &&
    read("/proc/vmstat") is Some(vmstat) else {
    return None
  }
  guard stall_total(cpu, "some") is Some(cpu_some) &&
    stall_total(memory, "some") is Some(memory_some) &&
    stall_total(memory, "full") is Some(memory_full) else {
    return None
  }
  let (compact_stalls, alloc_stalls) = vm_stalls(vmstat)
  Some({ cpu_some, memory_some, memory_full, compact_stalls, alloc_stalls })
}

///|
/// The machine's counters at the window's start (main.ts `pressure`).
let pressure_before : Ref[Pressure?] = Ref(None)

///|
/// ops/pressure.ts `pressureSince`: what the counters went up by in the window, as the held thread's log says it.
fn pressure_since(before : Pressure?, after : Pressure?, fields : Map[String, Json]) -> Unit {
  guard before is Some(a) && after is Some(b) else { return }
  let ms = (x : Double, y : Double) => Json::number(if y > x { ((y - x) / 1000.0).round() } else { 0.0 })
  let n = (x : Double, y : Double) => Json::number(if y > x { y - x } else { 0.0 })
  fields["windowCpuWaitMs"] = ms(a.cpu_some, b.cpu_some)
  fields["windowMemoryWaitMs"] = ms(a.memory_some, b.memory_some)
  fields["windowMemoryStallMs"] = ms(a.memory_full, b.memory_full)
  fields["windowCompactStalls"] = n(a.compact_stalls, b.compact_stalls)
  fields["windowAllocStalls"] = n(a.alloc_stalls, b.alloc_stalls)
}

///|
/// The loop's sample (main.ts's HELD_EVERY_MS): `late` ms past `every`, said where it was held, with the window's
/// statements, what the runtime waits on and how the process is.
fn Station::sampled(self : Station, late : Double, every : Int) -> Unit {
  let (longest, ms, calls) = take_queries()
  let before = pressure_before.val
  pressure_before.val = pressure_now()
  if late >= HELD_SAID_MS {
    let fields : Map[String, Json] = {
      "heldMs": Json::number(late.round()),
      "windowMs": Json::number((late + every.to_double()).round()),
      "awaiting": Json::number(self.host.rt.awaiting().to_double()),
      "longestQueryMs": Json::number(longest.round()),
      "windowQueriesMs": Json::number(ms.round()),
      "windowQueries": Json::number(calls.to_double()),
    }
    if open_fds() is Some(n) {
      fields["openFds"] = Json::number(n.to_double())
    }
    if self_rss_bytes() is Some(rss) {
      fields["rssMb"] = Json::number(@ops_platform.forewarn_mb(rss))
    }
    pressure_since(before, pressure_before.val, fields)
    p51_log("WARN", "station", "the main thread was held", fields=Json::object(fields))
  }
}

///|
/// forewarn.ts `lookAt`: what is looked at now, of the data directory.
fn Station::look(self : Station) -> @ops_platform.ForewarnLook {
  let disk = disk_of(self.data)
  let wal = match (try { Ok(@drive.stat(path([self.data, "stillfail.db-wal"]))) } catch { e => Err(e) }) {
    Ok(st) => st.size
    Err(_) => 0.0
  }
  {
    disk_free: disk.map(d => d.0),
    disk_total: disk.map(d => d.1),
    wal_bytes: wal,
    open_fds: open_fds(),
    rss: self_rss_bytes(),
    relay_conflict: match self.bus {
      Some(b) => (b.mesh_relay_conflict.val)()
      None => false
    },
  }
}

///|
/// What of the machine runs out, said (main.ts `forewarned`, at each sample).
fn Station::forewarned(self : Station, forewarn : @ops_platform.Forewarn) -> Unit {
  for w in forewarn.look(self.look(), @host.now().to_double()) {
    p51_log("WARN", w.at, w.message, fields=w.fields)
  }
}

///|
/// main.ts `memory: now`: how the process is, as health.json says it, and what forewarn.ts looks at.
fn Station::memory_now(self : Station) -> Unit {
  let l = self.look()
  let fields : Map[String, Json] = {}
  if l.rss is Some(rss) {
    fields["rssMb"] = Json::number(@ops_platform.forewarn_mb(rss))
  }
  if l.open_fds is Some(n) {
    fields["openFds"] = Json::number(n.to_double())
  }
  fields["front"] = Json::string(match self.bus { Some(b) => (b.mesh_front_kind.val)(); None => "direct" })
  fields["presenceOnline"] = Json::boolean(match self.bus { Some(b) => (b.cloud_reached.val)(); None => false })
  fields["relayConflict"] = Json::boolean(l.relay_conflict)
  if (l.disk_free, l.disk_total) is (Some(free), Some(total)) {
    fields["diskFreeMb"] = Json::number(@ops_platform.forewarn_mb(free))
    fields["diskTotalMb"] = Json::number(@ops_platform.forewarn_mb(total))
  }
  fields["walBytes"] = Json::number(l.wal_bytes)
  fields["awaiting"] = Json::number(self.host.rt.awaiting().to_double())
  p51_log("INFO", "memory", "now", fields=Json::object(fields))
}
