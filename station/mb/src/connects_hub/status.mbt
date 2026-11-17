// What an agent is doing, said where it works while it works (connects/status.ts; the words: sessions/chat.ts
// `toolStatus`): one line per thread, changed at most once an interval (the first change at once), one change at a time
// and in order, only the latest of those said meanwhile, cleared ("") once the turn ends. How a platform shows it is
// its own (`show`).

///|
pub struct StatusLine {
  /// Runs a wait as a fiber of whoever owns the line (its waits end with it).
  priv run : (async () -> Unit) -> Unit
  priv clock : Clock
  priv interval : Double
  /// Shows `status` ("": the turn ended) at `now`: whether it was shown (one that was not is tried again with the
  /// next). Given the line, for what it was last told (`message_ts`, `page`).
  show : async (StatusLine, String, Double) -> Bool
  /// The message that started the work, and the session's page in still.fail (where there is one), as last said.
  mut message_ts : String?
  mut page : String?
  priv mut shown : String
  priv mut wanted : String
  /// When it last changed (never, at first: the first change goes at once, whatever the clock says).
  priv mut last_at : Double
  priv mut timer : Bool
  priv sending : Turns
}

///|
pub fn StatusLine::new(
  run : (async () -> Unit) -> Unit,
  clock : Clock,
  interval : Double,
  show : async (StatusLine, String, Double) -> Bool,
) -> StatusLine {
  {
    run,
    clock,
    interval,
    show,
    message_ts: None,
    page: None,
    shown: "",
    wanted: "",
    last_at: -@double.infinity,
    timer: false,
    sending: Turns::new(),
  }
}

///|
pub fn StatusLine::say(self : StatusLine, status : String, message_ts? : String? = None, page? : String? = None) -> Unit {
  if message_ts is Some(_) {
    self.message_ts = message_ts
  }
  if page is Some(_) {
    self.page = page
  }
  self.wanted = status
  if self.timer {
    return
  }
  self.timer = true
  // On the clock of whoever runs it (a TestClock in tests).
  (self.run)(async fn() {
    let now = (self.clock.now)()
    let wait = if status == "" {
      0.0
    } else {
      let d = self.last_at + self.interval - now
      if d > 0.0 {
        d
      } else {
        0.0
      }
    }
    (self.clock.sleep)(wait)
    self.due((self.clock.now)())
  })
}

///|
async fn StatusLine::due(self : StatusLine, now : Double) -> Unit {
  self.timer = false
  if self.wanted == self.shown {
    return
  }
  self.last_at = now
  let was = self.shown
  let next = self.wanted
  // Shown as it goes: said again meanwhile, it does not go twice; not shown after all, it goes with the next.
  self.shown = next
  self.sending.run(async fn() {
    if !(self.show)(self, next, now) && self.shown == next {
      self.shown = was
    }
  })
}
