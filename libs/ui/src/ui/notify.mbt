// The system's notifications, through the framework (as @hostapi's notify.mbt has them): a test's fake host keeps what
// the app shows (Tester::notices) and taps one (Tester::tap_notice) as the system would (its nt_*, fake_host.mbt).

///|
/// A notification the app had shown: its channel, its tag (shown again by it: the same one, replaced), its title and
/// words, what it opens when tapped.
#derive(Eq, Debug)
pub(all) struct Notice {
  channel : String
  tag : String
  title : String
  body : String
  opens : String
}

///|
/// Shows a notification (@hostapi.notice_show): one of the same tag is replaced.
pub fn notice_show(channel~ : String, tag~ : String, title~ : String, body~ : String, opens~ : String) -> Unit {
  @hostapi.notice_show(channel~, tag~, title~, body~, opens~)
}

///|
/// Takes back the notification of `tag` (@hostapi.notice_cancel).
pub fn notice_cancel(tag : String) -> Unit {
  @hostapi.notice_cancel(tag)
}

///|
/// What the system said of its notifications since a frame last read it (notices_arrive), each a signal with how
/// many have come: the notification tapped (what it opens), the answer to the last ask. What reads them (the app's
/// poll, told once its frame is built: Ctx::after_build) is built again in the frame they come in, whether or not
/// anything else of it is: the host keeps them and only asks for a frame, telling nothing of what changed.
priv struct NoticesSaid {
  opened : @signals.Signal[(Int, String)]
  answer : @signals.Signal[(Int, Bool)]
  perm_tick : @signals.Signal[Int]
  mut opened_taken : Int
  mut answer_taken : Int
  mut last_arrived : (Bool, String)?
  mut saw_other : Bool
}

///|
// kept across runs: put back by each Tester (notices_reset)
let notices_said : NoticesSaid = {
  opened: @signals.signal((0, "")),
  answer: @signals.signal((0, false)),
  perm_tick: @signals.signal(0),
  opened_taken: 0,
  answer_taken: 0,
  last_arrived: None,
  saw_other: false,
}

///|
/// As at the start: nothing said, nothing taken.
fn notices_reset() -> Unit {
  notices_said.opened.set((0, ""))
  notices_said.answer.set((0, false))
  notices_said.perm_tick.set(0)
  notices_said.opened_taken = 0
  notices_said.answer_taken = 0
  notices_said.last_arrived = None
  notices_said.saw_other = false
}

///|
/// Hosts whose notification permission is refreshed asynchronously (macOS, iOS, Windows, Linux): excludes Android
/// (synchronous Binder) and Web (`Notification.permission`). Reads `@hostapi.platform()` directly so `set_platform`
/// overrides never toggle host polling.
fn poll_notice_permission() -> Bool {
  match @hostapi.platform() {
    0 | 1 | 3 | 5 => true
    _ => false
  }
}

///|
/// What the system said of its notifications since the last frame, read of it as a frame begins (frame_drawn, as the
/// streams and the native views are) or as the app asks between frames: each its signal set, once.
fn notices_arrive() -> Unit {
  let opened = @hostapi.notice_opened()
  if opened != "" {
    let (n, _) = notices_said.opened.untracked()
    notices_said.opened.set((n + 1, opened))
  }
  match @hostapi.notice_answer() {
    Some(yes) => {
      let (n, _) = notices_said.answer.untracked()
      notices_said.answer.set((n + 1, yes))
    }
    None => ()
  }
  if poll_notice_permission() {
    let now = Some(@hostapi.notice_permission_state())
    if now != notices_said.last_arrived || notices_said.saw_other {
      notices_said.last_arrived = now
      notices_said.saw_other = false
      notices_said.perm_tick.set(notices_said.perm_tick.untracked() + 1)
    }
  }
}

///|
/// What the notification tapped opens, once ("" none since the last ask: @hostapi.notice_opened): read as a signal,
/// what reads it built again as one is tapped.
pub fn notice_opened() -> String {
  if !frame_running.val {
    notices_arrive()
  }
  let (n, opens) = notices_said.opened.get()
  if n > notices_said.opened_taken {
    notices_said.opened_taken = n
    opens
  } else {
    ""
  }
}

///|
/// What the system lets the app show, together with whether the host is still awaiting its first asynchronous
/// permission read (`@hostapi.notice_permission_state`). On async-refresh hosts, subscribes to `perm_tick` and reads
/// `@hostapi.notice_permission_state()` live (without mutating any signal); `notices_arrive()` increments `perm_tick`
/// whenever the host value differs from `last_arrived` or a between-frame read observed another value (`saw_other`),
/// preserving live between-frame reads while preventing ABA skips and multi-subscriber missed wakeups.
pub fn notice_permission_state() -> (Bool, String) {
  if poll_notice_permission() {
    notices_said.perm_tick.get() |> ignore
    let now = @hostapi.notice_permission_state()
    if Some(now) != notices_said.last_arrived {
      notices_said.saw_other = true
    }
    return now
  }
  @hostapi.notice_permission_state()
}

///|
/// What the system lets the app show (@hostapi.notice_permission): "granted", "denied", "ask", "default" (a browser's:
/// never answered, its prompt shown whenever asked), "unknown". A Tester's host lets it unless the test says otherwise
/// (Tester::set_notice_permission).
pub fn notice_permission() -> String {
  notice_permission_state().1
}

///|
/// Asks the system to let the app show notifications (@hostapi.notice_ask): false when nothing was asked (allowed
/// already, or a host that cannot tell has no way to ask: "unknown", as macOS, Windows and the web say). Under a
/// Tester the person answers as the test said (Tester::set_notice_reply), from the next frame.
pub fn notice_ask() -> Bool {
  @hostapi.notice_ask()
}

///|
/// The system's answer to the last `notice_ask`, once (@hostapi.notice_answer): Some(true) allowed, Some(false) refused,
/// None not yet. Read as a signal: what reads it built again as the answer comes.
pub fn notice_answer() -> Bool? {
  if !frame_running.val {
    notices_arrive()
  }
  let (n, yes) = notices_said.answer.get()
  if n > notices_said.answer_taken {
    notices_said.answer_taken = n
    Some(yes)
  } else {
    None
  }
}

///|
/// Opens the system's settings of the app's notifications, where they are allowed or turned off
/// (@hostapi.notice_settings): false where it has none to open (a browser's page). Under a Tester counted
/// (Tester::notice_settings_opened), none where it plays a browser (platform 4).
pub fn notice_settings() -> Bool {
  @hostapi.notice_settings()
}

///|
/// Whether the system shows the number the app puts on its icon (@hostapi.badge_shown; a Tester's as the system it
/// plays does). A program playing another system (set_platform), as that system does: macOS and iOS.
pub fn badge_shown() -> Bool {
  if said_platform.val < 0 {
    @hostapi.badge_shown()
  } else {
    platform_badge(platform())
  }
}

///|
/// Whether a system shows the number on the app's icon where nothing tells otherwise: macOS and iOS.
fn platform_badge(platform : Int) -> Bool {
  platform == 0 || platform == 1
}

///|
/// What the system lets the app show from the next frame on: "granted", "denied", "ask" (not asked yet, as Android's),
/// "default" (never answered, as a browser's: refused when asked, it stays so), "unknown".
pub fn Tester::set_notice_permission(self : Tester, state : String) -> Unit {
  self.fake.notice_perm = state
  self.fake.wants = true
}

///|
/// What the person answers when the app asks to show notifications: Some(true) allows, Some(false) refuses, None never
/// answers (the dialog left open).
pub fn Tester::set_notice_reply(self : Tester, reply : Bool?) -> Unit {
  self.fake.notice_reply = reply
}

///|
/// How often the app asked to show notifications (notice_ask).
pub fn Tester::notice_asks(self : Tester) -> Int {
  self.fake.notice_asks
}

///|
/// How often the app opened the system's settings of its notifications (notice_settings).
pub fn Tester::notice_settings_opened(self : Tester) -> Int {
  self.fake.notice_settings
}
