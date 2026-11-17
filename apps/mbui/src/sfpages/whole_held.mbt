// A chat's whole row (sfbase's whole_row: the list's rows are made without it) asked as the hand comes to what shows
// the chat (a list's row, a board's card) and held while what reads it is open: what opens waits for it (sfbase's
// press_wait, while what it was pressed in stays as it was) and opens whole the frame it is answered.

///|
/// What holds chat `item`'s whole row for one row or card: what asked it, what waits for it, and `busy`, whether
/// anything else of the row's holds it now (the hand on it, its menu open).
priv struct WholeHeld {
  src : Source
  item : () -> ChatItem
  busy : () -> Bool
  ask : @sfbase.WholeAsk
  mut wait : @sfbase.PressWait?
}

///|
fn WholeHeld::new(src : Source, item : () -> ChatItem, busy : () -> Bool) -> WholeHeld {
  { src, item, busy, ask: @sfbase.WholeAsk::new(), wait: None }
}

///|
/// Its whole row asked, unless it is held already.
fn WholeHeld::asks(self : WholeHeld) -> Unit {
  self.ask.ask(self.src, @signals.untracked(self.item))
}

///|
/// Whether a press waits for it now.
fn WholeHeld::waits(self : WholeHeld) -> Bool {
  self.wait is Some(w) && w.waiting()
}

///|
/// Let go of where nothing reads it: not busy, nothing waiting for it.
fn WholeHeld::idle(self : WholeHeld) -> Unit {
  @signals.untracked(fn() {
    if !(self.busy)() && !self.waits() {
      self.ask.let_go()
    }
  })
}

///|
/// What waits for it ended (the row gone, or taken for another chat): what it asked let go of by what follows.
fn WholeHeld::wait_gone(self : WholeHeld) -> Unit {
  match self.wait {
    Some(w) => {
      self.wait = None
      w.end()
    }
    None => ()
  }
}

///|
/// All of it let go of: what waits ended, what was asked let go (the row let go, or taken for another chat).
fn WholeHeld::drop(self : WholeHeld) -> Unit {
  self.wait_gone()
  self.ask.let_go()
}

///|
/// `run` with its chat's whole row: now where it is answered, else the frame it is, while what it was pressed in stays
/// as it was (sfbase's press_wait); else nothing, `gone` done, and what it asked let go of.
fn WholeHeld::then(self : WholeHeld, run : (ChatItem) -> Unit, gone : () -> Unit) -> Unit {
  self.asks()
  self.wait_gone()
  let w = @sfbase.press_wait(fn() { @sfbase.whole_answered(self.src, (self.item)()) }, fn() {
    match @signals.untracked(fn() { @sfbase.whole_row(self.src, (self.item)()) }) {
      Some(i) => run(i)
      None => ()
    }
    self.idle()
  }, let_go=fn() {
    gone()
    self.idle()
  })
  self.wait = if w.waiting() { Some(w) } else { None }
}
