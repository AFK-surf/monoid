// Moving a station's things to another, module by module (the core's `stationMove` topic: client/core-ts/src/move.ts,
// of the station's GET /move): what its page (src/sfpages station_move_node.mbt) and its station's 迁移 read, and the
// station it moves to, remembered for that station on this device (the prefs' `moveTo`).

///|
/// What of station `address` moves to `to` ("" none chosen: what its station's page reads), with `opened`'s items
/// open ("" none), `limit` of them (a page at a time as its list is scrolled: 0 the first page).
pub fn move_of(core : Core, address : String, to : String, opened : String, limit? : Int = 0) -> Read {
  let params : Map[String, Json] = { "station": str(address), "to": str(to), "module": str(opened) }
  if limit > move_page {
    params["limit"] = Json::number(limit.to_double())
  }
  (core.topic)("stationMove", params).get()
}

///|
/// A page of a module's items, and the most the page shows of one (the core's move.ts MOVE_PAGE, MOVE_SHOWN_MOST).
pub let move_page : Int = 50

///|
pub let move_shown_most : Int = 200

///|
/// The station chosen here a moment ago for each station's things, before the core's prefs say it, by its address.
// kept across runs: what was chosen in this one (each comes again from the prefs once they say it)
let move_chosen : @sf.LiveMap[String, String] = @sf.LiveMap::new()

///|
/// The station `address`'s things go to as chosen on this device (its id; "" none chosen).
pub fn move_target(core : Core, address : String) -> String {
  let kept = text(field((core.topic)("prefs", Map([])).get().value, "moveTo"), address)
  match move_chosen.get(address) {
    Some(v) => v
    None => kept
  }
}

///|
/// The station `address`'s things go to chosen (`id`): shown so at once, kept on this device (prefs.set).
pub fn move_target_set(core : Core, address : String, id : String) -> Unit {
  move_chosen[address] = id
  (core.call)("prefs.set", obj([("moveTo", obj([(address, str(id))]))]), fn(r) {
    if r is Err(_) {
      move_chosen.remove(address)
    }
  })
}

///|
/// Whether station `address`'s page shows 迁移: something of it moved, moving, stopped or failed (the core's `active`),
/// whether its station offers moving now or not.
pub fn move_shown(core : Core, address : String) -> Bool {
  flag(move_of(core, address, "", "").value, "active")
}

///|
/// Whether its ⋯ offers 迁移到另一台 station (station `s`): it is online and offers moving (`move_said`).
pub fn move_offered(s : Json?) -> Bool {
  flag(s, "online") && move_said(s)
}

///|
/// Whether station `s` says it takes moves (its overview's `move.offered`: every station since moving graduated,
/// 2026-11-21; a stable one from before says not, and none from before moving says anything).
pub fn move_said(s : Json?) -> Bool {
  flag(field(field(s, "overview"), "move"), "offered")
}
