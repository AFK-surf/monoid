// This device's bottom bars (the phone's frame draws them: src/sfapp bar.mbt), as the core keeps them in the prefs and
// as switched here: what the settings' 下方栏 shows and changes, and a place's icon.

///|
/// Every place a bar can hold (the core's BAR_PLACES).
// kept across runs: a table, never written
let bar_places : Array[String] = [
  "chats", "files", "remote", "stations", "profiles", "connects", "usage", "archive", "vault",
]

///|
/// The bars before the core has said (BARS_DEFAULT; legacy before remote for older replays).
fn default_bars_for(remote : Bool) -> (Array[Array[String]], Int) {
  if remote {
    ([["chats", "files", "profiles", "stations"], ["remote", "archive", "usage", "connects"]], 0)
  } else {
    ([["chats", "files", "profiles", "stations"], ["archive", "usage", "connects", "vault"]], 0)
  }
}

///|
fn default_bars() -> (Array[Array[String]], Int) {
  default_bars_for(true)
}

///|
/// An iPhone Duo's one bar before any is kept for the workspace (the system's tab bar: one, never swiped between): the
/// tabs it showed before its bar could be set.
// kept across runs: a table, never written
let native_default_bar : Array[String] = ["chats", "files", "stations"]

///|
/// The bars whole, as the core keeps them (prefs.ts barsOf): each one to four known places, none twice; empty ones
/// dropped; none left, the default ones; the one in view one of them.
fn bars_of(v : Json?) -> (Array[Array[String]], Int) {
  let sets : Array[Array[String]] = []
  for s in items(v, "sets") {
    let kept : Array[String] = []
    match s {
      Array(a) =>
        for p in a {
          match p {
            String(k) if bar_places.contains(k) && !kept.contains(k) && kept.length() < 4 =>
              kept.push(k)
            _ => ()
          }
        }
      _ => ()
    }
    if kept.length() > 0 {
      sets.push(kept)
    }
  }
  if sets.length() == 0 {
    return default_bars()
  }
  let cur = number(v, "current").to_int()
  (sets, if cur < 0 { 0 } else if cur >= sets.length() { sets.length() - 1 } else { cur })
}

///|
/// The bars as switched here, before the prefs say it.
pub let bars_picked : @signals.Signal[(Array[Array[String]], Int)?] = @signals.signal(None)

///|
/// The bars of workspace `ws`: switched here, else its own as the prefs keep them (`barsBy`), else an iPhone Duo's one
/// (native_default_bar: the core's `bars` is always the phone's two, BARS_DEFAULT, till one is set), else everyone's
/// (`bars`).
pub fn bars_in(src : Source, ws : String) -> (Array[Array[String]], Int) {
  match bars_picked.get() {
    Some(b) => b
    None => {
      let prefs = src.topic("prefs", {}).get().value
      match field(field(prefs, "barsBy"), ws) {
        Some(Object(_)) as b => bars_of(b)
        _ if @sf.native_on() => ([native_default_bar.copy()], 0)
        _ =>
          match field(prefs, "bars") {
            Some(Object(_)) as b => bars_of(b)
            _ => default_bars_for(@signals.untracked(fn() { (src.asks_terminals)() }))
          }
      }
    }
  }
}

///|
/// The places of the bars as kept (`sets`), in their order, none twice: the phone's one bar's slots, then its menu's
/// rows (bar_slots).
pub fn bars_flat(sets : Array[Array[String]]) -> Array[String] {
  let flat : Array[String] = []
  for set in sets {
    for p in set {
      if !flat.contains(p) {
        flat.push(p)
      }
    }
  }
  flat
}

///|
/// How many slots a bar has: with more places than that, its last slot stands for the rest (its menu: More).
pub let bar_slots_most : Int = 4

///|
/// A workspace's bar as the phone's own bar (sfapp's bar.mbt) and the system's tab bar (sfdesk's rail_native.mbt) both
/// lay its places out: `flat`, every place of the bars kept, in their order, none twice; `fixed`, those with a slot
/// each (all of `flat` where it has `bar_slots_most` or fewer, else all but the last slot's worth of them); `menu`, the
/// places of the last slot's menu, in their order (none: every place has its slot); `more`, the menu's place the last
/// slot stands for now ("" with no menu): the place shown where it is one of the menu's, else the one last shown
/// from the menu in this workspace (bar_more_shown), else the menu's first.
#derive(Eq)
pub(all) struct BarSlots {
  flat : Array[String]
  fixed : Array[String]
  menu : Array[String]
  more : String
}

///|
/// The places drawn on the bar, a slot each: `fixed`, then, with a menu, the place its slot stands for.
pub fn BarSlots::slots(self : BarSlots) -> Array[String] {
  if self.menu.is_empty() {
    self.fixed
  } else {
    let slots = self.fixed.copy()
    slots.push(self.more)
    slots
  }
}

///|
/// The menu page each workspace's last slot stands for: the one last shown from it, kept for this run.
// kept across runs: emptied as a run begins (bar_more_reset)
let bar_more_kept : Map[String, String] = Map([])

///|
/// Told as bar_more_kept changes: what reads it reads again.
// kept across runs: a count whose changes alone are read
let bar_more_said : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })

///|
/// A place of the menu shown in workspace `ws` (picked in the menu of either bar, or come to another way): what the
/// last slot stands for there from now, till another of the menu's is shown.
pub fn bar_more_shown(ws : String, place : String) -> Unit {
  if bar_more_kept.get(ws) != Some(place) {
    bar_more_kept[ws] = place
    bar_more_said.set(bar_more_said.untracked() + 1)
  }
}

///|
/// As at the start (tests).
pub fn bar_more_reset() -> Unit {
  bar_more_kept.clear()
  bar_more_said.set(0)
}

///|
/// The menu's places of `flat`: those past the bar's own slots, where there are more places than slots.
pub fn bar_menu_of(flat : Array[String]) -> Array[String] {
  if flat.length() <= bar_slots_most {
    []
  } else {
    flat[bar_slots_most - 1:].to_owned()
  }
}

///|
/// bar_slots' of the places `flat` (the bars kept, flattened), `active` the place shown.
pub fn bar_slots_of(flat : Array[String], ws : String, active : String?) -> BarSlots {
  let menu = bar_menu_of(flat)
  if menu.is_empty() {
    return { flat, fixed: flat, menu, more: "" }
  }
  let fixed = flat[0:bar_slots_most - 1].to_owned()
  let more = match active {
    Some(a) if menu.contains(a) => a
    _ => {
      bar_more_said.get() |> ignore
      match bar_more_kept.get(ws) {
        Some(k) if menu.contains(k) => k
        _ => menu[0]
      }
    }
  }
  { flat, fixed, menu, more }
}

///|
/// Every place of workspace `ws`'s bars, in their order, none twice. An iPhone Duo whose bar was never set has its
/// three (native_default_bar) and, after them, the other places the bars start with (default_bars_for): its menu's.
fn bar_flat_in(src : Source, ws : String) -> Array[String] {
  let flat = bars_flat(bars_in(src, ws).0)
  if @sf.native_on() && bars_picked.get() is None {
    let prefs = src.topic("prefs", {}).get().value
    if !(field(field(prefs, "barsBy"), ws) is Some(Object(_))) {
      for p in bars_flat(default_bars_for(@signals.untracked(fn() { (src.asks_terminals)() })).0) {
        if !flat.contains(p) {
          flat.push(p)
        }
      }
    }
  }
  flat
}

///|
/// Workspace `ws`'s bar as it is laid out, `active` the place shown (none: no place of the bars): read again as the
/// bars kept change (the prefs' `barsBy`, bars_picked) and as another of the menu's places is shown (bar_more_shown).
pub fn bar_slots(src : Source, ws : String, active : String?) -> BarSlots {
  bar_slots_of(bar_flat_in(src, ws), ws, active)
}

///|
/// Another bar in view (AppState.setBars): shown at once, kept whole as the workspace's (`prefs.set {barsBy}`).
pub fn set_bars(src : Source, ws : String, sets : Array[Array[String]], cur : Int) -> Unit {
  bars_picked.set(Some((sets, cur)))
  let whole = Json::object({
    "sets": Json::array(sets.map(fn(s) { Json::array(s.map(fn(p) { Json::string(p) })) })),
    "current": Json::number(cur.to_double()),
  })
  let by : Map[String, Json] = Map([])
  by[ws] = whole
  (src.call)("prefs.set", Json::object({ "barsBy": Json::object(by) }), answer_unread)
}

///|
/// A place's icon (Station's is the stations' glyph of their state once read, bar_glyph).
pub fn place_icon(place : String) -> String {
  match place {
    "chats" => "chats"
    "files" => "folder"
    "remote" => "monitor"
    "profiles" => "quota"
    "connects" => "plug"
    "usage" => "chart"
    "archive" => "archive"
    "vault" => "key"
    _ => "server"
  }
}

///|
/// What place `place` opens on of the core's that the device holds (the lists `lasting` keeps), for workspace `ws`:
/// 文件's stations with their drives, Station's, Profile's, 连接's, 密钥's: what only the device's own data answers (the
/// core's rule 4: no request of a station for it). 用量's and 已归档's, and how each station up is reached (Station's),
/// only once a finger is on their tab (`shown`): theirs a station is asked for, or sampled, as they are shown (the
/// core's rules 2 and 4), so never before.
fn place_reads(src : Source, ws : String, scope : String, place : String, shown : Bool) -> Array[(String, Map[String, Json])] {
  let of = Json::string(ws)
  // (the stations' rows, as every list asks them: one subscription for every place that opens on them)
  let stations = stations_asked(ws)
  match place {
    "files" => [("workspace", { "workspace": of }), ("stations", stations)]
    "remote" => {
      let reads : Array[(String, Map[String, Json])] = [("stations", stations)]
      if shown && hold(src, scope, "stations", stations).get().value is Some(Array(all)) {
        let terms_on = @signals.untracked(fn() { (src.asks_terminals)() })
        for s in all {
          if field(Some(s), "online") == Some(Json::boolean(true)) && field(Some(s), "station") is Some(String(address)) {
            reads.push(("screens", { "station": Json::string(address) }))
            if terms_on {
              reads.push(("terminals", { "station": Json::string(address) }))
            }
          }
        }
      }
      reads
    }
    "stations" => {
      let reads : Array[(String, Map[String, Json])] = [("stations", stations)]
      // (each station up as it is reached: sampled while shown, the core's rule 2, so only with a finger on the tab)
      if shown && hold(src, scope, "stations", stations).get().value is Some(Array(all)) {
        for s in all {
          if field(Some(s), "online") == Some(Json::boolean(true)) && field(Some(s), "station") is Some(String(address)) {
            reads.push(("stationNet", { "station": Json::string(address) }))
          }
        }
      }
      reads
    }
    "profiles" => [("profiles", { "scope": of })]
    "connects" => [("stations", stations), ("connects", { "scope": of, "mine": Json::boolean(false) })]
    "vault" => [("vaults", { "workspace": of })]
    // (as their pages ask them with nothing chosen in them: sfpages usage_ask's seven days, the archive's first page)
    "usage" if shown => {
      let asks = [("usage", { "scope": of, "days": Json::number(7.0) })]
      if (src.asks_agent_rates)() { asks.push(("agentRates", { "scope": of })) }
      asks
    }
    "archive" if shown => [("archive", { "scope": of, "limit": Json::number(60.0) })]
    _ => []
  }
}

///|
/// Places read ahead: which (their workspace and names: "" none), under what name they are held (`hold`'s scope, ""
/// none).
priv struct Ahead {
  mut of : String
  mut scope : String
}

///|
/// Those of the bar in view, and the one a finger went down on.
// kept across runs: put back as a run begins (ahead_reset)
let ahead_bar : Ahead = { of: "", scope: "" }

///|
// kept across runs: put back as a run begins (ahead_reset)
let ahead_press : Ahead = { of: "", scope: "" }

///|
/// Those of the bar's menu, while it is open.
// kept across runs: put back as a run begins (ahead_reset)
let ahead_menu : Ahead = { of: "", scope: "" }

///|
/// The places of the bar's menu while it is open (none: shut): what they open on is asked from the moment it opens, as
/// the bar's own slots' is while the bar is there, so a row picked a moment later finds it answered.
// kept across runs: put back as a run begins (ahead_reset)
let places_menu_now : @signals.Signal[Array[String]] = @signals.signal([], same=fn(a, b) { a == b })

///|
/// The bar's menu opened on `places` (none: it closed).
pub fn places_menu_open(places : Array[String]) -> Unit {
  places_menu_now.set(places)
}

///|
/// The place whose tab a finger went down on last ("" none, or let go of): what it opens on is asked from then, so its
/// tap, a moment later, finds it answered (as a chat's row asks for its chat as it is pressed: sfpages' chat_row_node).
// kept across runs: put back as a run begins (ahead_reset)
let place_pressed_now : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })

///|
/// When what the press asked is let go of (places_ahead_node): the moment the finger left the tab, or, where it switched
/// to the place, the moment that place has come in (go_place's motion over); -1 while the finger is down.
// kept across runs: put back as a run begins (ahead_reset)
let place_press_ends : @signals.Signal[Double] = @signals.signal(-1.0, same=fn(a, b) { a == b })

///|
/// A finger went down on place `place`'s tab.
pub fn place_pressed(place : String) -> Unit {
  place_press_ends.set(-1.0)
  place_pressed_now.set(place)
}

///|
/// The finger on the bar let go at `at` (lifted, moved off, called off): what its press asked let go of then, or, where
/// a place was switched to as it did (place_switched), once that place has come in.
pub fn place_press_lifted(at : Double) -> Unit {
  if place_pressed_now.untracked() != "" && place_press_ends.untracked() < at {
    place_press_ends.set(at)
  }
}

///|
/// A place switched to, as a finger on the bar did it: come in by `until` (its motion's end, go_place's), what the
/// press asked held till then, as the page it opens on is first built before.
pub fn place_switched(until : Double) -> Unit {
  if place_pressed_now.untracked() != "" && place_press_ends.untracked() < until {
    place_press_ends.set(until)
  }
}

///|
/// `places` of workspace `ws` held under `scope` (place_reads; `shown`: a finger is on that place's tab), what was
/// held before for others let go of first.
fn Ahead::hold_places(self : Ahead, src : Source, ws : String, scope : String, places : Array[String], shown : Bool) -> Unit {
  ahead_outside_build()
  let of = ws + " " + places.join(",")
  // (others now: held under a name of their own first, then what was held let go of, so what both read stays read,
  // never let go of and asked again between)
  let was = if self.of != of { self.scope } else { "" }
  if self.of != of {
    ahead_count.val += 1
    self.of = of
    self.scope = scope + "#" + ahead_count.val.to_string()
  }
  // (owned by none of what asked: what is held lives till let go of, not till the reaction that asked runs again)
  let owner = @signals.set_owner(None)
  for place in places {
    for read in place_reads(src, ws, self.scope, place, shown) {
      hold(src, self.scope, read.0, read.1) |> ignore
    }
  }
  @signals.set_owner(owner) |> ignore
  if was != "" {
    let_go(src, was)
  }
}

///|
/// What is held ahead is held and let go of at causes' moments (places_ahead_node's reactions, its timeline), never as
/// a build runs: held.mbt's let_go defers what a build going on still reads, which would keep what was read ahead past
/// its moment. Each time it was, counted (places_ahead_in_build), for the tests to hold at none.
fn ahead_outside_build() -> Unit {
  if held_building.val {
    ahead_in_build.val += 1
  }
}

///|
// kept across runs: only counted on
let ahead_in_build : Ref[Int] = Ref(0)

///|
/// How many times what is read ahead was held or let go of as a build ran (ahead_outside_build): none, ever.
pub fn places_ahead_in_build() -> Int {
  ahead_in_build.val
}

///|
/// How many sets of places have been held ahead: each its own name to be held under (Ahead::hold_places).
// kept across runs: only counted on
let ahead_count : Ref[Int] = Ref(0)

///|
/// What is held let go of.
fn Ahead::release(self : Ahead, src : Source) -> Unit {
  ahead_outside_build()
  if self.scope != "" {
    let_go(src, self.scope)
  }
  self.of = ""
  self.scope = ""
}

///|
/// What the places of the bar open on (place_reads) asked of the core ahead of them, for as long as the bar is there:
/// from the moment `bar` says it is (the workspace whose bar shows: it came in, its page came back), held till it says
/// none (its page gone from view under another, the stack at rest: Nav::root_shows), what changes of it meanwhile coming
/// as what changed, not whole again; another bar or workspace in view, its places in their place. And what a place
/// opens on that a station is asked for as it shows (用量, 已归档; Station's ways reached, sampled while shown: the
/// core's rules 2 and 4), asked as a finger goes down on its tab and held till it leaves the tab, or, where it switched
/// to it, till that place has come in (place_switched): never while the place is not to be shown. Both at their
/// causes' moments, whatever frames are drawn: the page a place opens on is first built before either lets go, so it
/// takes over what is held. What the core said is kept (`lasting`), so a place shows it at once, not its bones.
pub fn places_ahead_node(v : @view.View, src : Source, bar : () -> String?) -> Unit {
  v.reacts(
    fn() {
      guard @signals.untracked(fn() { (src.reads_ahead)() }) else { return None }
      match bar() {
        Some(ws) => {
          // (the bar's slots: the first places kept, in their order; the rest are its menu's, sfapp's bar_menu.mbt)
          let flat = bar_flat_in(src, ws)
          Some((ws, if flat.length() > bar_slots_most { flat[0:bar_slots_most].to_owned() } else { flat }))
        }
        None => None
      }
    },
    fn(want) {
      match want {
        Some((ws, places)) => ahead_bar.hold_places(src, ws, "ahead/" + ws, places, false)
        None => ahead_bar.release(src)
      }
    },
  )
  // (the bar's menu's places, while it is open)
  v.reacts(
    fn() {
      guard @signals.untracked(fn() { (src.reads_ahead)() }) else { return None }
      let places = places_menu_now.get()
      match bar() {
        Some(ws) if !places.is_empty() => Some((ws, places))
        _ => None
      }
    },
    fn(want) {
      match want {
        Some((ws, places)) => ahead_menu.hold_places(src, ws, "ahead-menu/" + ws, places, false)
        None => ahead_menu.release(src)
      }
    },
  )
  // (the pressed place's, while the finger is on it, till it lets go)
  let off : Ref[() -> Unit] = Ref(fn() {  })
  v.reacts(
    fn() {
      guard @signals.untracked(fn() { (src.reads_ahead)() }) else { return None }
      let pressed = place_pressed_now.get()
      let ends = place_press_ends.get()
      match bar() {
        Some(ws) if pressed != "" => {
          // (Station's: each station up reached, as the stations come to be known)
          if pressed == "stations" || pressed == "remote" {
            station_rows(src, ws) |> ignore
          }
          Some((ws, pressed, ends))
        }
        _ => None
      }
    },
    fn(want) {
      (off.val)()
      off.val = fn() {  }
      match want {
        Some((ws, pressed, ends)) => {
          ahead_press.hold_places(src, ws, "ahead-press/" + ws, [pressed], true)
          if ends >= 0.0 {
            off.val = v.at_moment(ends, fn() {
              ahead_press.release(src)
              place_pressed_now.set("")
            })
          }
        }
        None => ahead_press.release(src)
      }
    },
  )
}

///|
/// Whether what the places open on is held ahead of them now (places_ahead_node).
pub fn places_ahead_open() -> Bool {
  ahead_bar.scope != "" || ahead_press.scope != "" || ahead_menu.scope != ""
}

///|
fn ahead_reset() -> Unit {
  for a in [ahead_bar, ahead_press, ahead_menu] {
    a.of = ""
    a.scope = ""
  }
  places_menu_now.set([])
  bar_more_reset()
  place_pressed_now.set("")
  place_press_ends.set(-1.0)
}
