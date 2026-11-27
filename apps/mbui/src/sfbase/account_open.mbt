// An account's page opened only once what it shows is answered. Its page reads its station (`station`: the profile as
// the station has it) and the account (`profile`, one account whole: views/views.ts), and the list it is opened from
// holds neither (its rows are what they draw, ProfileRow), so an account's page opened at the press would show its
// bones till they came, where it opened whole before the list's rows were rows. So the press asks them, and the page
// opens as they are answered (press_wait: at once where they are already, else the moment they are, while what it was
// pressed in stays as it was); meanwhile the screen stays as it was (the coordinator of the migration, 2026-11-12:
// opening an account's page draws no bones). So too a choice that switches what its page reads (switch_answered).

///|
/// What the host is told of an account's page opened by a press (still.fail's Android app's BarTiming, as a switch of
/// the bar is: PostHog's `bar_switch`, its `to` "account"): `asked` as the press asks what the page reads (the topics
/// subscribed after it timed, each to its first value), `opened` after the frame that put the page up. How long the
/// press waited, and for which answer, is then the host's to say (2026-11-15: opening an account's page waited a second
/// and more now and then, nothing said where). Nothing here reads a clock; None under a Tester.
pub(all) struct OpenTiming {
  asked : (String) -> Unit
  opened : (String) -> Unit
}

///|
/// The host's, set once as the app starts (src/stillfail reports.mbt).
// kept across runs: the host's, set once for the process; a test that sets one puts None back itself
pub let open_timing : Ref[OpenTiming?] = Ref(None)

///|
/// `open` (what puts the page `what` up) told to the host once done, after the frame that drew it, as open_timing says.
fn timed_open(what : String, open : () -> Unit) -> () -> Unit {
  match open_timing.val {
    Some(t) => {
      (t.asked)(what)
      fn() {
        open()
        @ui.after_frame(fn() { (t.opened)(what) })
      }
    }
    None => open
  }
}

///|
/// The workspace a station's topics are asked of (settings' station_scope): its address's, `ws` for one without it.
pub fn account_scope(ws : String, station : String) -> String {
  if station.contains("/") {
    @settings.workspace_of(station)
  } else {
    ws
  }
}

///|
/// What a profile's page on station `station` (of workspace `ws`), profile `id`, reads as it opens: its station whole,
/// the account it is of (settings' station_read, profile_read) and the workspaces the station is in, which its settings
/// list the account's workspaces by (sfpages' accounts.mbt `joined`): opened before those were answered, its card grew
/// a row a round trip after it came in.
pub fn profile_page_asks(ws : String, station : String, id : String) -> Array[(String, Map[String, Json])] {
  let scope = Json::string(account_scope(ws, station))
  [
    ("station", { "scope": scope, "station": Json::string(station) }),
    ("profile", { "scope": scope, "station": Json::string(station), "id": Json::string(id) }),
    ("memberships", { "station": Json::string(station) }),
  ]
}

///|
/// What an account's page of all its stations reads as it opens: the account by its key (settings'
/// profile_by_key_read).
pub fn account_page_asks(ws : String, key : String) -> Array[(String, Map[String, Json])] {
  [("profile", { "scope": Json::string(ws), "key": Json::string(key) })]
}

///|
/// What the settings' route `r` reads of the core before it may open (open_answered): a profile's page and an
/// account's; none for any other route, which opens at once.
pub fn route_asks(ws : String, r : @settings.Route) -> Array[(String, Map[String, Json])] {
  match r {
    Profile(station, id) => profile_page_asks(ws, station, id)
    ProfileAccount(key) => account_page_asks(ws, key)
    _ => []
  }
}

///|
/// What a press opening the settings' route `r` in workspace `w` asks before the page opens (open_answered), on `src`:
/// route_asks, and where a card, a panel or a sheet waits for what it reads too (gates_opens, MBUI_OPEN_WHOLE) all its
/// page reads as it is first drawn (page_reads.mbt route_reads, the same table the pane's and the stack's waits read),
/// so none opens on its bones while the core reads what the device holds; one that waits on a station opens at once,
/// showing that it waits.
pub fn route_open_asks(src : Source, w : Workspace, r : @settings.Route) -> Array[(String, Map[String, Json])] {
  if !(src.gates_opens)() {
    return route_asks(w.id, r)
  }
  route_reads(src, w.id, r).asks
}

///|
/// What follows the station's answer for a station's page opened by a press (route_open_then): what its part shown reads
/// as it is first drawn, by the code it reads it by (sfpages' station_node.mbt, set as the app starts), given the source,
/// the workspace, the station's address and the station whole as answered.
// kept across runs: set once for the process by sfpages' init, what reads a station's page there
pub let station_open_more : Ref[(Source, Workspace, String, Json) -> Array[(String, Map[String, Json])]] = Ref(fn(
  _,
  _,
  _,
  _,
) {
  []
})

///|
/// What a press opening the settings' route `r` in workspace `w` asks once what route_open_asks asked is answered
/// (asked_now's `then`), where what opens waits for what it shows (gates_opens): what follows from those answers in its
/// page (route_reads': a station's page what its part shown reads, station_open_more), so it never draws its blocks one
/// by one as the core answers them; None where nothing follows.
pub fn route_open_then(
  src : Source,
  w : Workspace,
  r : @settings.Route,
) -> ((((String, Map[String, Json])) -> Json?) -> Array[(String, Map[String, Json])])? {
  guard (src.gates_opens)() else { return None }
  route_reads(src, w.id, r).then
}

///|
/// How long at most a press opening route `r` waits for what it shows where it waits for it as a card or a panel does
/// (route_open_asks' own, not an account's: @sf.open_hold_ms), else as long as it takes.
pub fn route_open_most(src : Source, w : Workspace, r : @settings.Route) -> Double? {
  if (src.gates_opens)() && route_asks(w.id, r).is_empty() && !route_open_asks(src, w, r).is_empty() {
    Some(@sf.open_hold_ms)
  } else {
    None
  }
}

///|
/// `asks` asked of `src` now and held by what is returned till what opens has read them: whether each is answered (a
/// value, or an error the page says), and what holds them. A press that waits by press_wait itself takes them so (an
/// agent's history's 详情: what it opens keeps its own way, sfpages' history_details_open). With `then`, each time all
/// asked so far is answered, what it
/// gives that is not asked yet is asked and held with the rest (the array returned grows), and all is answered once it
/// gives nothing new: `then` is given how to read what was asked (by its ask: its value as the lease holding it has it,
/// None where it is not asked or not answered) and gives the asks that follow from it (a list's rows each reading a
/// topic of its own, their ids said only by the list's answer), worked out by the same code the page reads the answer
/// by, those asked already among them or not. What `then` reads it reads through the leases (`follow`, read where the
/// wait reads it), so no subscription is made but theirs; what it asks is made outside what reads now, owned by nothing
/// (as press_wait's wait is), so the wait reading again does not let it go.
pub fn asked_now(
  src : Source,
  asks : Array[(String, Map[String, Json])],
  then? : (((String, Map[String, Json])) -> Json?) -> Array[(String, Map[String, Json])],
) -> (() -> Bool, Array[TopicLease]) {
  let key = fn(a : (String, Map[String, Json])) { a.0 + "\u{1}" + Json::object(a.1).stringify() }
  let leases = asks.map(fn(a) { src.lease_topic(a.0, a.1) })
  let keys = asks.map(key)
  let told = fn(l : TopicLease) {
    match l.follow() {
      Some(t) => t.value is Some(_) || t.error is Some(_) || ((src.gates_opens)() && t.waiting)
      // (let go of: nothing to wait for)
      None => true
    }
  }
  let read = fn(a : (String, Map[String, Json])) -> Json? {
    match keys.search(key(a)) {
      Some(i) =>
        match leases[i].follow() {
          Some(t) => t.value
          None => None
        }
      None => None
    }
  }
  let answered = fn() {
    while true {
      for i in 0..<leases.length() {
        if !told(leases[i]) {
          return false
        }
      }
      let more = match then {
        Some(after) => after(read).filter(fn(a) { !keys.contains(key(a)) })
        None => []
      }
      if more.is_empty() {
        return true
      }
      // (asked outside what reads now: held by its lease alone, not by the wait's reading)
      let owner = @signals.set_owner(None)
      @signals.untracked(fn() {
        for a in more {
          if !keys.contains(key(a)) {
            keys.push(key(a))
            leases.push(src.lease_topic(a.0, a.1))
          }
        }
      })
      @signals.set_owner(owner) |> ignore
    }
    true
  }
  (answered, leases)
}

///|
/// `open` (what puts an account's page on top: the settings' push) done once each of `asks` is answered, asked of `src`
/// now; at once where they are answered already. What they ask is handed to the entry `open` puts on top, which takes
/// it as its view is made and lets it go at the end of the frame of its first build (pages.mbt hand_over); let go at
/// once where nothing was put on top, and where the press waits no more, with what else the press opened for it
/// (`let_go`: a draft the page was to show). Made in a press's handler, as press_wait is. What waits is returned: given
/// up by the press's control where a press after it asks for another.
pub fn open_answered(
  src : Source,
  asks : Array[(String, Map[String, Json])],
  open : () -> Unit,
  let_go? : () -> Unit = fn() {  },
  then? : (((String, Map[String, Json])) -> Json?) -> Array[(String, Map[String, Json])],
  most? : Double,
) -> PressWait {
  if asks.is_empty() || src.read_only {
    return press_wait(fn() { true }, open)
  }
  let (answered, leases) = asked_now(src, asks, then?)
  press_wait(answered, fn() { hand_over(leases, open) }, let_go=fn() {
    leases.each(fn(l) { l.cancel() })
    let_go()
  }, most?)
}

///|
/// `show` (what shows an account's page in a pane in place of the one there, no entry put on top: a place's side
/// list's pick) done once each of `asks` is answered, as open_answered; what they ask handed to the page shown for
/// `at`, taken as it is first built and let go at that frame's end (pages.mbt hand_over_shown, shown_read).
pub fn show_answered(
  src : Source,
  asks : Array[(String, Map[String, Json])],
  at : String,
  show : () -> Unit,
  then? : (((String, Map[String, Json])) -> Json?) -> Array[(String, Map[String, Json])],
) -> Unit {
  show_answered_wait(src, asks, at, show, then?) |> ignore
}

///|
/// show_answered, what waits returned (press_wait's, done at once where nothing is to wait for): given up by the press's
/// control where a press after it asks for another (a tab of a chat's panel pressed while another waits).
pub fn show_answered_wait(
  src : Source,
  asks : Array[(String, Map[String, Json])],
  at : String,
  show : () -> Unit,
  then? : (((String, Map[String, Json])) -> Json?) -> Array[(String, Map[String, Json])],
) -> PressWait {
  if asks.is_empty() || src.read_only {
    return press_wait(fn() { true }, show)
  }
  let (answered, leases) = asked_now(src, asks, then?)
  press_wait(answered, fn() { hand_over_shown(at, leases, show) }, let_go=fn() { leases.each(fn(l) { l.cancel() }) })
}

///|
/// A choice that switches what the same page reads (用量's days and split), nothing made anew to take what it asks.
/// Pressed, `asks` (what the page reads as it is first drawn for that choice, said by the code it reads by) are asked of
/// `src` now; the page stays as it is meanwhile, the choice showing what was pressed by a state of its own. Once each is
/// answered (at once where they are already), `switch_to` writes what the page reads by, told as what the answer tells
/// (view's `answering`: what it changes comes whole, no way set out by it), at the end of what is running (the press's
/// event, the answer's, the frame): a switch told while a frame is being built would show part of each in it. What was
/// asked is handed over with it to the page's readers by `at` (hand_over_shown): each that reads it anew says so as it
/// has read it (shown_read), and the leases are let go at the end of that frame, its subscriptions then its readers' own.
/// Given up (press_wait: the page left, the workspace switched, something else put up; and by its caller where another
/// choice is pressed, by the PressWait returned), what was asked is let go and `let_go` run (the choice put back to what
/// is shown).
pub fn switch_answered(
  src : Source,
  asks : Array[(String, Map[String, Json])],
  at : String,
  switch_to : () -> Unit,
  let_go? : () -> Unit = fn() {  },
  then? : (((String, Map[String, Json])) -> Json?) -> Array[(String, Map[String, Json])],
) -> PressWait {
  // (told while a frame is drawn, after it brought the window's tree: at that frame's end, so the frame shows the page
  // wholly as it was, never its words read anew over what is laid out as it was; in a press or between frames, at the
  // end of that event, before the next frame)
  let told = fn() { @ui.after_frame(fn() { @view.answering(switch_to) }) }
  // (asking nothing ahead where the source's run did not: a replay of a run from before, switched at the press)
  if asks.is_empty() || src.read_only || !(src.switches_ahead)() {
    return press_wait(fn() { true }, told)
  }
  let (answered, leases) = asked_now(src, asks, then?)
  // (what was asked handed over with the switch, so the frame its readers read it anew in is the one after it)
  let go = fn() { @ui.after_frame(fn() { hand_over_shown(at, leases, fn() { @view.answering(switch_to) }) }) }
  // (the choice the page switches by, shown at the press: a menu it was chosen in done with it then, never held open
  // as what it opens is waited for, press_wait's `holds`)
  press_wait(answered, go, holds=false, let_go=fn() {
    leases.each(fn(l) { l.cancel() })
    let_go()
  })
}

///|
/// A panel or a sheet drawn by the old view (`@sf.panel`, whose body reads as frames build it, not as it is made: no
/// OpenGate of its own) opened by a press: where what opens waits for what it shows (gates_opens, MBUI_OPEN_WHOLE),
/// once `asks` (what its body reads as it is first drawn, said by the code it reads them by) are answered, the screen as
/// it was meanwhile (press_wait, open_hold_ms at most); else, or asking nothing, at once. What was asked is held by
/// what it opened, as long as that is drawn (presented_held): it puts nothing on the stack (app.nav), so open_answered's
/// hand_over would let it go at once, between the press and the frame its body first reads it in, read then anew from
/// nothing (the chat's 任务 sheet drawn in its bones).
pub fn open_old_whole(src : Source, asks : Array[(String, Map[String, Json])], open : () -> Unit) -> Unit {
  if !(src.gates_opens)() || src.read_only || asks.is_empty() {
    open()
    return
  }
  let (answered, leases) = asked_now(src, asks)
  press_wait(answered, fn() { presented_held(leases, open) }, let_go=fn() { leases.each(fn(l) { l.cancel() }) }, most=@sf.open_hold_ms)
  |> ignore
}

///|
/// A panel of the window's tree (`@sf.panel_nodes`) opened by a press, once `asks` (what its nodes read as they are
/// first made, said by the code they read them by) are answered, the screen as it was meanwhile (press_wait): so what
/// waits on a station (a terminal's 控制中心 its station's screens) comes with the panel, never pushing its rows down
/// after it came; at once where they are answered already. What was asked is held by the panel as long as it is drawn
/// (presented_held), so its nodes take it over without asking anew. A replay of a run from before asks nothing ahead
/// (switches_ahead), opened at once. What waits is returned: given up by the press's control where it is pressed again
/// meanwhile.
pub fn present_answered(
  src : Source,
  asks : Array[(String, Map[String, Json])],
  open : () -> Unit,
) -> PressWait {
  if asks.is_empty() || src.read_only || !(src.switches_ahead)() {
    return press_wait(fn() { true }, open)
  }
  let (answered, leases) = asked_now(src, asks)
  press_wait(answered, fn() { presented_held(leases, open) }, let_go=fn() { leases.each(fn(l) { l.cancel() }) })
}

///|
/// show_answered_wait, waiting as well for `ready` (what the page shown reads that is no topic: a call's answer it keeps,
/// an agent's history's transcript's place) before `show`; a replay of a run from before asks nothing ahead
/// (switches_ahead), shown at once.
pub fn show_answered_with(
  src : Source,
  asks : Array[(String, Map[String, Json])],
  ready : () -> Bool,
  at : String,
  show : () -> Unit,
) -> PressWait {
  if src.read_only || !(src.switches_ahead)() {
    return press_wait(fn() { true }, show)
  }
  let (answered, leases) = asked_now(src, asks)
  press_wait(fn() { answered() && ready() }, fn() { hand_over_shown(at, leases, show) }, let_go=fn() {
    leases.each(fn(l) { l.cancel() })
  })
}

///|
/// `open` run (what puts up something presented: a panel, a sheet), `leases` handed to what it put up (or the sheet it
/// came to be a page of): held by the window's tree past what asked them, let go as that is drawn no more (closed and
/// gone, @sf.presented_drawn_of); at once where nothing is drawn.
fn presented_held(leases : Array[TopicLease], open : () -> Unit) -> Unit {
  let readers : Array[TopicLease] = []
  for lease in leases {
    match prepare_chat_handoff(lease) {
      Some(reader) => readers.push(reader)
      None => ()
    }
  }
  open()
  let serial = @sf.last_presented()
  let let_go_all = fn() {
    for r in readers {
      r.release()
    }
    readers.clear()
  }
  if readers.is_empty() || !@signals.untracked(fn() { @sf.presented_drawn_of(serial) }) {
    let_go_all()
    return
  }
  // (followed outside any build, as press_wait follows: stopped as it lets them go)
  let stop : Ref[(() -> Unit)?] = Ref(None)
  let gone = Ref(false)
  let owner = @signals.set_owner(None)
  stop.val = Some(
    @signals.untracked(fn() {
      @signals.effect(fn() {
        if !gone.val && !@sf.presented_drawn_of(serial) {
          gone.val = true
          @signals.untracked(fn() {
            let_go_all()
            match stop.val {
              Some(s) => s()
              None => ()
            }
          })
        }
      })
    }),
  )
  @signals.set_owner(owner) |> ignore
  // (gone already as it was first followed: stopped now that it can be)
  if gone.val {
    match stop.val {
      Some(s) => s()
      None => ()
    }
  }
}
