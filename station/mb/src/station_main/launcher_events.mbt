// What the launcher did to recover while no station could say it (station/native/launcher/src/lifecycle.rs `record`:
// <data>/run/launcher-events.jsonl), said once in the log by the station that comes up next, as
// station/src/ops/launcher-events.ts says it: the file taken first (a rename), each event's own fields at its level.

///|
/// The fields said of an event (launcher-events.ts FIELDS, in its order).
let launcher_event_fields : Array[String] = [
  "kind", "at", "pid", "version", "how", "uptimeMs", "taken", "failures", "heartbeatTimeoutMs", "misses", "probeMs",
  "retries", "reason", "exitTimeoutMs", "healthAgeMs", "rssBytes", "openFds", "heldMaxMs", "front", "presenceOnline",
  "relayConflict",
]

///|
/// One line of the file: its level ("error" or "warn"), kind and fields; None for one that is not an event
/// (launcher-events.ts `launcherEventOf`).
fn parse_launcher_event_line(line : String) -> (String, String, Json)? {
  guard attempt(() => @json.parse(line)) is Ok(Object(m)) else { None }
  guard m.get("kind") is Some(String(kind)) && kind != "" else { None }
  let fields : Map[String, Json] = Map([])
  for name in launcher_event_fields {
    if m.get(name) is Some(value) {
      fields[name] = value
    }
  }
  let level = match m.get("level") {
    Some(String("error")) => "error"
    Some(String("warn")) => "warn"
    _ =>
      if kind == "node_hung_killed" || kind == "node_crashed" || kind == "front_hung_killed" {
        "error"
      } else {
        "warn"
      }
  }
  Some((level, kind, Json::object(fields)))
}

///|
fn launcher_event_logged(level : String, kind : String, fields : Json) -> Unit {
  p51_log(if level == "error" { "ERROR" } else { "WARN" }, "launcher", kind, fields~)
}

///|
/// Says each event the launcher kept (`emit`, the log by default) and removes them: how many.
fn report_launcher_events(data : String, emit? : (String, String, Json) -> Unit = launcher_event_logged) -> Int {
  let dir = path([data, "run"])
  let claimed = path([dir, "launcher-events.\{@drive.pid()}.jsonl"])
  guard attempt(() => @drive.rename(path([dir, "launcher-events.jsonl"]), claimed)) is Ok(_) else { return 0 }
  let text = read_text(claimed).unwrap_or("")
  @drive.rm_force(claimed)
  let mut n = 0
  for line in text.split("\n") {
    let line = line.to_owned()
    if line.trim().to_owned() == "" {
      continue
    }
    guard parse_launcher_event_line(line) is Some((level, kind, fields)) else { continue }
    emit(level, kind, fields)
    n += 1
  }
  n
}

// What ended a Node station by a fatal error (src/main.ts `recordCrash`: <data>/run/node-crash.json), said once in
// the log by the station that comes up next, as launcher-events.ts `reportNodeCrash` says it.

///|
/// The fields said of a crash (launcher-events.ts CRASH_FIELDS, in its order).
let node_crash_fields : Array[String] = ["at", "pid", "version", "origin", "error"]

///|
/// The file's crash: its own fields; None for one that is not a crash (launcher-events.ts `nodeCrashOf`).
fn parse_node_crash(text : String) -> Json? {
  guard attempt(() => @json.parse(text)) is Ok(Object(m)) else { None }
  guard m.get("origin") is Some(String(origin)) && origin != "" else { None }
  guard m.get("error") is Some(String(error)) && error != "" else { None }
  let fields : Map[String, Json] = Map([])
  for name in node_crash_fields {
    if m.get(name) is Some(value) {
      fields[name] = value
    }
  }
  Some(Json::object(fields))
}

///|
fn node_crash_logged(fields : Json) -> Unit {
  p51_log("ERROR", "station", "previous process ended with fatal error", fields~)
}

///|
/// Says the crash the station before kept (`emit`, the log by default) and removes it: whether there was one.
fn report_node_crash(data : String, emit? : (Json) -> Unit = node_crash_logged) -> Bool {
  let dir = path([data, "run"])
  let claimed = path([dir, "node-crash.\{@drive.pid()}.json"])
  guard attempt(() => @drive.rename(path([dir, "node-crash.json"]), claimed)) is Ok(_) else { return false }
  let text = read_text(claimed).unwrap_or("")
  @drive.rm_force(claimed)
  guard parse_node_crash(text) is Some(fields) else { return false }
  emit(fields)
  true
}
