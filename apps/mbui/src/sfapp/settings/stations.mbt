// The workspace's stations: how this device says a machine's CPU, and what a station's page keeps while it is in the
// stack (its list and its page are made once as nodes: sfpages'
// stations_list.mbt, station_node.mbt).

///|
/// Whether this device says its machines' CPU as how much of it is used, not how much is idle (the prefs' `cpuDial`
/// busy, turned by pressing the CPU's dial on a station's page): every place that says a machine's CPU says it so.
pub fn cpu_busy_of(prefs : Json?) -> Bool {
  text(prefs, "cpuDial") == "busy"
}

///|
/// cpu_busy_of, as `core`'s prefs say it now.
pub fn cpu_busy(core : Core) -> Bool {
  cpu_busy_of((core.topic)("prefs", Map([])).get().value)
}

///|
/// A machine's `meters` as this device says them (cpu_busy_of): `busy`, the CPU's (`short` CPU) words and figure are
/// how much of it is used (占用 28%, 28: what is not `left`) instead of what is idle; its fill, level, name and tip are
/// the same either way (its cells were always filled as far as is used). The others are as they are, the same objects.
pub fn meters_said(meters : Array[Json], busy : Bool) -> Array[Json] {
  if !busy {
    return meters
  }
  meters.map(fn(m) {
    match m {
      Object(o) if text(Some(m), "short") == "CPU" => {
        // (as far as its cells are filled: what is not left, as the chip's fill has it)
        let used = (100 - count(Some(m), "left")).to_string()
        let turned = Map::from_iter(o.iter())
        turned["remaining"] = Json::string(@sf.t("web-pages.stations.page.cpuBusyChip", args=[("percent", used)]))
        turned["big"] = Json::string(used)
        Json::object(turned)
      }
      _ => m
    }
  })
}

///|
/// The page's part shown, by station, by its name (StationPage.tsx Part: overview 概览, processes 进程, settings 设置,
/// machine 软件与设备); none, the overview. Kept while the page is in the stack; a login's link opens the settings
/// (mark_login).
pub let station_parts : @sf.LiveMap[String, String] = @sf.LiveMap::new()

///|
/// Whose page has its 高级网络设置 opened, by station (opened by the person, or the fixture's
/// settings-station-network); kept while the page is in the stack.
pub let station_network_open : Map[String, Bool] = Map([])

///|
/// Whether station `s` is this machine's (the host's station, one id in every workspace it is in): Station's list puts
/// it first, tagged 本机 (the user, 2026-11-16).
pub fn is_this_machine(s : Json?) -> Bool {
  let id = text(s, "id")
  id != "" && local_station_id() == id
}
