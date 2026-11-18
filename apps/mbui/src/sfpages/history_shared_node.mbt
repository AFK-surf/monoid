// What an agent's history's head and details are of on every screen alike (小屏's page of its own, sfapp's
// history.mbt and history_node.mbt; 中屏 and 大屏's side panel, sfdesk's history.mbt): whether the agent works now, the
// station it runs on as the stations' rows name and mark it, and what 详情 reads as it is first drawn, which pressing it
// asks first (history_details_open).

///|
/// Whether agent `a` works now, or waits to (its status running or queued): its turn can be stopped.
pub fn history_working(a : Json?) -> Bool {
  match text(a, "status") {
    "running" | "queued" => true
    _ => false
  }
}

///|
/// The workspace a station is of, from its address (ws/station).
pub fn history_station_scope(station : String) -> String {
  match station.find("/") {
    Some(i) => station.exact_view(end=i).to_owned()
    None => station
  }
}

///|
/// The station at `station` as the stations the app knows name and mark it (its workspace's rows), None where they do
/// not list it (yet).
pub fn history_station(src : Source, station : String) -> @sfbase.Station? {
  @sfbase.station_marks(src, history_station_scope(station)).iter().find_first(fn(s) { s.address == station })
}

///|
/// The name of the station at `station`: the stations' rows', else `said` (as the chat's row said it).
pub fn history_station_name(src : Source, station : String, said : String) -> String {
  match history_station(src, station) {
    Some(s) => s.name
    None => said
  }
}

///|
/// What agent `key`'s history's details on `station` read as they are first drawn (all but the chat's agent, the
/// head's), each as it is read by: its card, its station's machine, its figures, the stations' rows its station is
/// named and marked from; and where they show what the core has under way (`doing`: 中屏 and 大屏's context line),
/// that. What 详情 pressed asks first.
pub fn history_details_asks(station : String, key : String, doing? : Bool = false) -> Array[(String, Map[String, Json])] {
  let asks = [
    agent_card_ask(station, key),
    history_host_ask(station),
    history_ask(station, key),
    @sfbase.station_rows_ask(history_station_scope(station)),
  ]
  if doing {
    asks.push(@sfbase.doing_ask())
  }
  asks
}
