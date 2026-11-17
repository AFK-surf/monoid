// What build each device a lock here names last ran, as this station saw it ask (station/src/mesh/device-builds.ts),
// and the builds a moved workspace's readers need (station/src/api/moved-from.ts; their reasons there).

///|
/// The first build that takes a workspace whose chain moved, read as it moved beside its people's logs.
pub let moved_from_build : Int = 9144

///|
/// The first build that reads a removal of the root's person naming the root's log as taking them out.
pub let root_out_from_build : Int = 9244

///|
/// How many person logs a device of a release before LOGS_ANY_FROM_BUILD keeps of a workspace at most.
pub let logs_before : Int = 256

///|
/// The first build that keeps every log a workspace's stations give and reads them by their heads.
pub let logs_any_from_build : Int = 9275

///|
/// The first build counted as a release's (station/src/api/oldest.ts `COUNTED_FROM`): one under it cannot be told
/// apart from a development build.
pub let counted_from : Int = 1000

///|
/// What a device was last seen running: its highest build (-1: none said) and when (unix seconds).
pub(all) struct Seen {
  build : Int
  at : Double
}

///|
/// Where they are kept: the store's `device_builds`, else memory alone.
pub(all) struct BuildsKept {
  device_builds : () -> Array[(String, Int, Double)]
  put_device_build : (String, Int, Double) -> Unit
  device_builds_since : (Double) -> Double
}

///|
pub struct DeviceBuilds {
  since : Double
  priv rows : Map[String, Seen]
  priv kept : BuildsKept?
}

///|
let day : Double = 86400.0

///|
pub fn DeviceBuilds::new(kept : BuildsKept?, now : Double) -> DeviceBuilds {
  let rows : Map[String, Seen] = Map([])
  let since = match kept {
    Some(k) => {
      for r in (k.device_builds)() {
        rows[r.0] = { build: r.1, at: r.2 }
      }
      (k.device_builds_since)(now)
    }
    None => now
  }
  { since, rows, kept }
}

///|
/// Device `id` asked saying `build` (none: none) at `at`: kept where its build rose or it was seen another day.
pub fn DeviceBuilds::saw(self : DeviceBuilds, id : String, build : Int?, at : Double) -> Unit {
  let b = build.unwrap_or(-1)
  let was = self.rows.get(id)
  if was is Some(w) && b <= w.build && (at / day).floor() == (w.at / day).floor() {
    return
  }
  let wb = match was {
    Some(w) => w.build
    None => -1
  }
  let wa = match was {
    Some(w) => w.at
    None => 0.0
  }
  let next : Seen = { build: if b > wb { b } else { wb }, at: if at > wa { at } else { wa } }
  self.rows[id] = next
  if self.kept is Some(k) {
    (k.put_device_build)(id, next.build, next.at)
  }
}

///|
/// What is kept of the devices `ids` (those never seen left out), with `since`: `{since, devices}`.
pub fn DeviceBuilds::of(self : DeviceBuilds, ids : Array[String]) -> Json {
  let devices : Map[String, Json] = Map([])
  for id in ids {
    if self.rows.get(id) is Some(s) {
      devices[id] = jobj([("build", jnum(s.build.to_double())), ("at", jnum(s.at))])
    }
  }
  jobj([("since", jnum(self.since)), ("devices", Json::object(devices))])
}
