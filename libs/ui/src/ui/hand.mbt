// The hand as what is built reads it (the way there's 3): what the pointer is over, what is
// pressed and what the press went down on, what was clicked or clicked twice since the frame before, what was held
// long, what has the focus, the current input, where the pointer is and whether it is down, the discrete events of the
// hand (a key, words typed, a press going down or up, a menu, what a reader asked). Each is said as each frame
// begins, before it is decided what it does again (frame_watch.mbt), as what the next build would see of it: a key of
// a set read by member (signals' Keyed: "is this row pointed at" changes as the pointer crosses its edge, not as it
// moves), a value read whole otherwise. What reads them (Ctx::hovered, lit, pressed, clicked, the focus's, Ctx::press)
// follows them, and is built again as they change for it: a pointer moved over what lights nothing builds nothing.

///|
/// What the frames read of the hand, as the frame being drawn began.
priv struct Hand {
  /// what the pointer is over and what holds that, as the last frame drew them (Ctx::hovered)
  mut over : @signals.Keyed[Int]
  /// what is pressed (Ctx::pressed), and what the press went down on and what holds it (Ctx::press_within)
  mut pressed : @signals.Keyed[Int]
  mut press_on : @signals.Keyed[Int]
  /// what was clicked, and clicked twice, since the frame before (Ctx::on_press, on_double_press, a part's Response); what a press held long
  /// was on (Ctx::long_press)
  mut clicked : @signals.Keyed[Int]
  mut double : @signals.Keyed[Int]
  mut held : @signals.Keyed[Int]
  /// what has the focus, as a member and as what it is (Ctx::has_focus, focused_id)
  mut focus : @signals.Keyed[Int]
  mut focus_id : @signals.Signal[Int]
  /// what has the focus where it shows (it came by the keyboard: Ctx::focus_shown), by member: told as that alone
  /// changes too, what has it not told
  mut shown : @signals.Keyed[Int]
  /// where the pointer is, whether it is down, the current input (Ctx::pointer, Ctx::press, pointing)
  mut pointer : @signals.Signal[(Double, Double)]
  mut down : @signals.Signal[Bool]
  mut pointing : @signals.Signal[Pointing]
  /// whether a finger or a button held down is past the slop of where the press was seen going down (Ctx::press's
  /// `moved`): what reads the press is built again as it goes past, not as it moves
  mut beyond : @signals.Signal[Bool]
  /// the hand's discrete events so far, counted (hand_event): what reads what came (a key, a menu asked for, words
  /// dropped) is built again as one comes
  mut events : @signals.Signal[Int]
  /// what was typed into a field of an old view with the focus so far, counted (hand_typed): its words and the keys it
  /// takes as its own, which go to its old view alone (view_host.mbt's typed_part); what reads the keys reads them
  /// with the discrete events (hand_keys_read), nothing else of what reads the hand (a press, a menu asked for)
  mut typed : @signals.Signal[Int]
  /// the pointer's presses going down or up so far, counted (hand_pressed): what reads how a press goes (Ctx::press, an
  /// editor's caret, a second finger) is built again as one does, nothing else
  mut presses : @signals.Signal[Int]
  /// what a reader asked something of (Ctx::ask_action), by member (Ctx::action_asked): what asked of none, not built
  mut asked : @signals.Keyed[Int]
  /// what `over` was last told, as a plain array (hand_over_same: whether the next frame tells it anew)
  mut over_now : Array[Int]
}

///|
// kept across runs: said anew as each frame begins (hand_arrive), from the Ctx of the run
let hand : Hand = {
  over: @signals.keyed(),
  pressed: @signals.keyed(),
  press_on: @signals.keyed(),
  clicked: @signals.keyed(),
  double: @signals.keyed(),
  held: @signals.keyed(),
  focus: @signals.keyed(),
  focus_id: @signals.signal(0),
  shown: @signals.keyed(),
  pointer: @signals.signal((0.0, 0.0), same=fn(a, b) { a.0 == b.0 && a.1 == b.1 }),
  down: @signals.signal(false),
  pointing: @signals.signal(Finger),
  beyond: @signals.signal(false),
  events: @signals.signal(0),
  typed: @signals.signal(0),
  presses: @signals.signal(0),
  asked: @signals.keyed(),
  over_now: [],
}

///|
/// The hand as the frame about to be drawn sees it, said (frame_drawn, before what it does again is decided): what of
/// it changed since the frame before tells what read it.
fn hand_arrive(c : Ctx) -> Unit {
  @signals.start_batch()
  let over = c.hover_in.copy()
  if c.hover != 0 {
    over.push(c.hover)
  }
  hand.over.set(over)
  hand.over_now = over
  hand.pressed.set(if c.down && c.active != 0 { [c.active] } else { [] })
  hand.press_on.set(c.press_on)
  hand.clicked.set(c.clicked)
  hand.double.set(c.double_clicked)
  hand.held.set(if c.held_on != 0 { [c.held_on] } else { [] })
  hand.focus.set(if c.focus != 0 { [c.focus] } else { [] })
  hand.focus_id.set(c.focus)
  hand.shown.set(if c.focus != 0 && c.focus_visible { [c.focus] } else { [] })
  hand.pointer.set((c.px, c.py))
  hand.down.set(c.down)
  let p = c.press_seen
  hand.beyond.set(c.down && ((c.px - p.x).abs() > press_slop || (c.py - p.y).abs() > press_slop))
  hand.pointing.set(pointing())
  hand.asked.set(c.asked_actions.map(fn(a) { a.0 }))
  @signals.end_batch()
}

///|
/// A discrete event of the hand came (a key, words typed, a press going down or up, a back, a menu, a reader's action):
/// what reads what comes (Ctx::keys, menu_asked, action_asked, tapped_anywhere) is built again.
fn hand_event() -> Unit {
  hand.events.set(hand.events.untracked() + 1)
}

///|
/// Words or a key typed into a field of an old view with the focus (view_host.mbt's typed_part): what reads the keys is
/// built again (hand_keys_read), and the field (Ctx::editor), not what reads how a press goes or a menu asked for (a
/// row's button elsewhere in the page).
fn hand_typed() -> Unit {
  hand.typed.set(hand.typed.untracked() + 1)
}

///|
/// What the hand's discrete events are, read (a menu asked for, words dropped, and the rest of what reads what came):
/// followed.
fn hand_events_read() -> Unit {
  hand.events.get() |> ignore
}

///|
/// The keys that came, read (Ctx::keys, key_pressed): followed, with the discrete events and what was typed into a
/// field (hand_typed).
fn hand_keys_read() -> Unit {
  hand.events.get() |> ignore
  hand.typed.get() |> ignore
}

///|
/// A press of the pointer went down or up (or was called off, or a second finger came): what reads how a press goes
/// built again (hand_presses_read), what reads the clicks by its own (a part's Response: hand's `clicked`) as it is one.
fn hand_pressed() -> Unit {
  hand.presses.set(hand.presses.untracked() + 1)
}

///|
/// How the pointer's presses go, read (Ctx::press and what follows a press as it goes): followed, with the discrete
/// events.
fn hand_presses_read() -> Unit {
  hand.events.get() |> ignore
  hand.presses.get() |> ignore
}

///|
/// Whether what the pointer is over in `c` (an old view's, as its last layout found it: Ctx::hover, hover_in) is what
/// the hand was last told it is over (hand_arrive): where not, the next frame tells it anew, what read it (Ctx::hovered)
/// drawn again by it.
fn hand_over_same(c : Ctx) -> Bool {
  let n = c.hover_in.length() + (if c.hover != 0 { 1 } else { 0 })
  if hand.over_now.length() != n {
    return false
  }
  for i, id in c.hover_in {
    if hand.over_now[i] != id {
      return false
    }
  }
  c.hover == 0 || hand.over_now[c.hover_in.length()] == c.hover
}

///|
/// Put back as a run begins (reset_globals): nothing over, pressed, clicked, held or focused.
fn hand_reset() -> Unit {
  for k in [hand.over, hand.pressed, hand.press_on, hand.clicked, hand.double, hand.held, hand.focus, hand.shown] {
    k.set([])
  }
  hand.over_now = []
  turns_reset(0.0)
}

///|
/// The focus as a pass of the frame's build left it (the layers' focus moved in, a field asked for it): said at once,
/// what read it told, so a build again of the frame sees it as this one left it.
fn hand_focus_said(c : Ctx) -> Unit {
  @signals.start_batch()
  if hand.focus_id.untracked() != c.focus {
    hand.focus.set(if c.focus != 0 { [c.focus] } else { [] })
    hand.focus_id.set(c.focus)
  }
  // (whether it shows, as that alone changes: a press letting a field keep it, unshown)
  hand.shown.set(if c.focus != 0 && c.focus_visible { [c.focus] } else { [] })
  @signals.end_batch()
}
