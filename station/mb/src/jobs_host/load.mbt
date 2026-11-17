// What a station tells the others of its machine and how busy it is (station/src/jobs/load.ts): `describe` answers
// it as `load`, station_list says it in a line (`summary`).

///|
/// What an older station's `describe` (no `load`) is said as.
pub let older : String = "unknown (older station)"

///|
let gib_bytes : Double = 1073741824.0

///|
fn gib(bytes : Double) -> String {
  let g = bytes / gib_bytes
  let shown = if g >= 100.0 { js_round(g) } else { js_round(g * 10.0) / 10.0 }
  "\{js_number(shown)} GiB"
}

///|
fn plural(n : Double, one : String, many? : String) -> String {
  let many = many.unwrap_or(one + "s")
  "\{js_number(n)} \{if n == 1.0 { one } else { many }}"
}

///|
/// A GPU in a few words: Apple's chip and its cores (just the cores when the CPU's name already says the chip),
/// NVIDIA's memory and how busy.
fn gpu_text(gpu : Json, cpu_model : String) -> String {
  let cores = num(field(gpu, "cores"))
  let name = match field(gpu, "name") {
    Some(String(s)) => s
    _ => "GPU"
  }
  let parts = []
  match cores {
    Some(c) => parts.push("\{js_number(c)} cores")
    None => ()
  }
  let total = num(field(gpu, "memoryTotalBytes"))
  let used = num(field(gpu, "memoryUsedBytes"))
  match total {
    Some(t) =>
      parts.push(
        match used {
          Some(u) => "\{gib(t - u)} of \{gib(t)} free"
          None => gib(t)
        },
      )
    None => ()
  }
  match num(field(gpu, "busy")) {
    Some(b) => parts.push("\{js_number(js_round(b * 100.0))}% busy")
    None => ()
  }
  if name == cpu_model && parts.length() > 0 {
    return "GPU \{join(parts, ", ")}"
  }
  if parts.length() > 0 {
    "GPU \{name} (\{join(parts, ", ")})"
  } else {
    "GPU \{name}"
  }
}

///|
fn deep(v : Json, keys : Array[String]) -> Json? {
  let mut at = Some(v)
  for k in keys {
    at = match at {
      Some(x) => field(x, k)
      None => None
    }
  }
  at
}

///|
/// One line saying a station's load (what `describe` answered as `load`), for station_list. Whatever a station leaves
/// out (or a newer one says otherwise) is left out of the line.
pub fn summary(load : Json) -> String {
  guard load is Object(_) else { return older }
  match field(load, "unavailable") {
    Some(String(u)) => return "unknown (\{u})"
    _ => ()
  }
  let cpu_model = text(load, "cpuModel")
  let machine = []
  let what = [field_or_null(load, "arch"), field_or_null(load, "os")].filter_map(v => match v {
    String(s) if s != "" => Some(s)
    _ => None
  })
  if what.length() > 0 {
    machine.push(join(what, " "))
  }
  match num(field(load, "cpus")) {
    Some(c) =>
      machine.push(
        "\{js_number(c)} cores\{if cpu_model != "" { " (\{cpu_model})" } else { "" }}",
      )
    None => ()
  }
  match field(load, "gpus") {
    Some(Array(gpus)) => for g in gpus { machine.push(gpu_text(g, cpu_model)) }
    _ => ()
  }
  let busy = []
  match num(deep(load, ["cpuBusy", "share"])) {
    Some(share) => {
      let when = match num(deep(load, ["cpuBusy", "seconds"])) {
        Some(s) => "over the last \{js_number(s)} s"
        None => "just now"
      }
      busy.push("CPU \{js_number(js_round(share * 100.0))}% busy \{when}")
    }
    None => ()
  }
  match field(load, "loadAvg") {
    Some(Array(a)) if a.length() == 3 =>
      busy.push("load \{js_join(a, " / ")} (1 / 5 / 15 min)")
    _ => ()
  }
  let room = []
  match (num(deep(load, ["memory", "totalBytes"])), num(deep(load, ["memory", "availableBytes"]))) {
    (Some(t), Some(f)) if t > 0.0 => room.push("memory \{gib(f)} of \{gib(t)} free")
    _ => ()
  }
  match (num(deep(load, ["disk", "totalBytes"])), num(deep(load, ["disk", "freeBytes"]))) {
    (Some(t), Some(f)) if t > 0.0 => room.push("disk \{gib(f)} of \{gib(t)} free")
    _ => ()
  }
  let running = match field(load, "running") {
    Some(Object(_) as r) | Some(Array(_) as r) => {
      let n = (k : String) => num(field(r, k)).unwrap_or(0.0)
      Some(
        "running " +
        join(
          [
            plural(n("remoteTasks"), "remote task"),
            plural(n("jobs"), "job"),
            plural(n("services"), "service"),
            plural(n("turns"), "agent turn"),
          ],
          ", ",
        ),
      )
    }
    _ => None
  }
  let relay = num(deep(load, ["relay", "ping", "ms"])).map(p => "relay ping \{js_number(p)} ms")
  let out = [Some(join(machine, ", ")), Some(join(busy, ", ")), Some(join(room, ", ")), running, relay].filter_map(s => match s {
    Some(t) if t != "" => Some(t)
    _ => None
  })
  join(out, "; ")
}

///|
/// `describe`'s answer for station_list {station}: as it came, its load said in a line too, or that an older station
/// says none.
pub fn detailed(described : Json) -> Json {
  guard described is Object(m) else { return described }
  let out = m.copy()
  match m.get("load") {
    None => out["load"] = jstr(older)
    Some(l) => out["summary"] = jstr(summary(l))
  }
  Json::object(out)
}

///|
/// The station's load now (load.ts `measure`): the host's sample, its GPUs too (read only where it says none at all),
/// the CPUs over about a minute, what runs here and the relay.
pub async fn measure(
  sample : async () -> Json,
  gpus : async () -> Json,
  recent_busy : async () -> (Double, Double)?,
  running : () -> Json,
  relay : () -> Json,
) -> Json {
  let info = sample() catch { _ => Json::null() }
  let g = match field(info, "gpus") {
    Some(x) => x
    None => gpus() catch { _ => Json::null() }
  }
  let recent = recent_busy() catch { _ => None }
  let cpus = num(field(info, "cpus"))
  let total = num(deep(info, ["memory", "totalBytes"]))
  let used = num(deep(info, ["memory", "usedBytes"]))
  let mem_total = match total {
    Some(t) if t > 0.0 => Some(t)
    _ => None
  }
  let known = !(deep(info, ["memory", "known"]) is Some(False))
  let available = match (mem_total, used) {
    (Some(t), Some(u)) if known && u >= 0.0 && u <= t => jnum(t - u)
    _ => Json::null()
  }
  let size = num(deep(info, ["disk", "totalBytes"]))
  let disk_total = match size {
    Some(s) if s > 0.0 => Some(s)
    _ => None
  }
  let free = num(deep(info, ["disk", "freeBytes"]))
  let opt = (d : Double?) => match d {
    Some(x) => jnum(x)
    None => Json::null()
  }
  let string_of = (v : Json?) => match v {
    None | Some(Null) => ""
    Some(x) => js_text(x)
  }
  obj([
    ("os", jstr(string_of(field(info, "os")))),
    ("arch", jstr(string_of(field(info, "arch")))),
    (
      "cpus",
      match cpus {
        Some(c) if c > 0.0 => jnum(c)
        _ => Json::null()
      },
    ),
    ("cpuModel", jstr(string_of(field(info, "cpuModel")))),
    (
      "cpuBusy",
      match recent {
        Some((busy, seconds)) => obj([("share", jnum(busy)), ("seconds", jnum(seconds))])
        None =>
          match field(info, "cpuBusy") {
            Some(Number(b, ..)) => obj([("share", jnum(b)), ("seconds", Json::null())])
            _ => Json::null()
          }
      },
    ),
    (
      "loadAvg",
      match field(info, "loadAvg") {
        Some(Array(_) as a) => a
        _ => Json::null()
      },
    ),
    ("memory", obj([("totalBytes", opt(mem_total)), ("availableBytes", available)])),
    (
      "disk",
      obj([
        ("path", jstr(string_of(deep(info, ["disk", "path"])))),
        ("totalBytes", opt(disk_total)),
        (
          "freeBytes",
          match (disk_total, free) {
            (Some(t), Some(f)) if f >= 0.0 && f <= t => jnum(f)
            _ => Json::null()
          },
        ),
      ]),
    ),
    ("gpus", g),
    ("running", running()),
    ("relay", relay()),
    ("checkedAt", opt(num(field(info, "checkedAt")))),
  ])
}

///|
/// The station's relay as its mesh last saw it (load.ts `Net`): where iroh homes, and the last ping.
pub struct Net {
  priv mut home : () -> String?
  priv mut ping : (String, Double)?
  priv mut on : Bool
}

///|
pub fn Net::new() -> Net {
  { home: () => None, ping: None, on: false }
}

///|
/// On the mesh: `home` says its relay; what it gives takes it off again.
pub fn Net::attach(self : Net, home : () -> String?) -> () -> Unit {
  self.home = home
  self.on = true
  () => {
    self.home = () => None
    self.ping = None
    self.on = false
  }
}

///|
pub fn Net::pinged(self : Net, relay : String, ms : Double) -> Unit {
  self.ping = Some((relay, js_round(ms)))
}

///|
pub fn Net::seen(self : Net) -> Json {
  if !self.on {
    return Json::null()
  }
  obj([
    (
      "home",
      match (self.home)() {
        Some(h) => jstr(h)
        None => Json::null()
      },
    ),
    (
      "ping",
      match self.ping {
        Some((r, ms)) => obj([("relay", jstr(r)), ("ms", jnum(ms))])
        None => Json::null()
      },
    ),
  ])
}
