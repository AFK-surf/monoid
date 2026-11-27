// A press that waits for the core to open something: a row's menu, its swipe's question and its 归档 key waiting for
// its chat's whole row (`chatRow`, whole_row.mbt), the chat page's "…" (sfpages' open_chat_menu), a new chat's model
// panel waiting for its `pick` (sfpages' model_triple), an account's page waiting for what it shows
// (account_open.mbt), the add page's choice of station waiting for that station's flow (sfpages new_profile.mbt).
// The rule held here, once for all of them: such a press waits
// only while what it was pressed in stays as it was (the page on top's stay, Nav::top_stay: the page not left, the
// workspace not switched; and nothing else put up by the presenters since, last_presented), and lets go of what it
// asked when it stops waiting without opening anything. Once answered while it is so, it does what it waited for, in
// the frame the answer comes, or at once where it is answered already. Pressed as a menu's item, the menu stays open as
// it was while it waits (@sf.choice_held), and what it opens comes in its place, a level of it, as one opened at once
// does; given up, the menu closes unsaid.

///|
/// A press waiting for the core (press_wait): whether it still waits, and what ends it.
pub struct PressWait {
  priv mut waiting : Bool
  priv mut stop : (() -> Unit)?
  priv ready : () -> Bool
  priv go : () -> Unit
  priv let_go : () -> Unit
  priv stay : (Int, Int)
  priv shown : Int
  /// the menu it was chosen in, held open as it was while it waits (@sf.choice_held)
  priv mut held : @sf.ChoiceHeld?
}

///|
/// Whether what press `w` was pressed in is as it was then (its `stay`, `shown`, the menu it holds still held): read
/// where it is read.
fn PressWait::still(self : PressWait) -> Bool {
  app.nav.top_stay() == self.stay &&
  @sf.last_presented() == self.shown &&
  (match self.held {
    Some(h) => h.still()
    None => true
  })
}

///|
/// A press that does `go` once `ready` (read where it is read: what it waits for of the core, through what holds it)
/// says it can: at once where it does already, else the moment it comes to, while what the press was pressed in stays
/// as it was; once that is no longer so (the page left, the workspace switched, something else put up), it waits no
/// more, does nothing and lets go of what it asked (`let_go`). Made in a press's handler (a system bar's choice is told
/// once the frame's builds are over: sfdesk rail_native.mbt) or before any frame (a fixture's ask), never as a view
/// builds, since `go` may run at once (a build asks through Ctx::after_build, as model_triple.mbt's does). A wait
/// outlives the pressed node and keeps its own read. `most`: it waits that long at most (a moment of the window's
/// tree's timeline from now), then does `go` as it is, while what it was pressed in stays as it was: what opens where
/// a card or a panel waits for what it reads of the device (@sf.open_hold_ms), never held longer than they are.
/// `holds`: pressed as a menu's item, that menu held open as it was while it waits (@sf.choice_held), what it opens
/// coming in its place; not where the press switches what is shown by a choice shown at once (switch_answered: 连接's
/// filter, the menu done with as the choice is made).
pub fn press_wait(
  ready : () -> Bool,
  go : () -> Unit,
  let_go? : () -> Unit = fn() {  },
  most? : Double,
  holds? : Bool = true,
) -> PressWait {
  let w : PressWait = {
    waiting: true,
    stop: None,
    ready,
    go,
    let_go,
    stay: @signals.untracked(fn() { app.nav.top_stay() }),
    shown: @sf.last_presented(),
    held: None,
  }
  if @signals.untracked(ready) {
    w.waiting = false
    go()
    return w
  }
  // (pressed as a menu's item: the menu held open as it was while it waits)
  w.held = if holds { @sf.choice_held() } else { None }
  if (most, @ui.view_tree()) is (Some(ms), Some(tree)) {
    let gate = @view.HoldGate::new(acknowledged=w.held is Some(_))
    let answered = Ref(false)
    w.stop = Some(fn() { gate.stop(give_up=false) })
    gate.open_when(
      tree.root(),
      most=ms,
      fn() {
        answered.val = ready()
        answered.val
      },
      while_still=fn() {
        // The deadline checks only whether the press still holds, without reading readiness again.
        answered.val = false
        w.waiting && w.still()
      },
      on_give_up=fn() { w.give_up() },
      fn() {
        guard w.waiting else { return }
        if answered.val {
          w.answered()
        } else {
          match w.held {
            Some(h) => {
              w.held = None
              w.end()
              h.close_then(go)
            }
            None => {
              w.end()
              go()
            }
          }
        }
      },
    )
    return w
  }
  let owner = @signals.set_owner(None)
  let stop = @signals.untracked(fn() {
    @signals.effect(fn() {
      guard w.waiting else { return }
      // (what it was pressed in first: once that is gone, what it waits for is not read again)
      if !w.still() {
        @signals.untracked(fn() { w.give_up() })
      } else if ready() {
        @signals.untracked(fn() { w.answered() })
      }
    })
  })
  @signals.set_owner(owner) |> ignore
  if w.waiting {
    w.stop = Some(stop)
  } else {
    stop()
  }
  w
}

///|
/// What it waited for answered while what it was pressed in stays as it was: done now, as the answer comes. Where it
/// holds the menu it was chosen in, done by that menu as a change of its own at that moment (@sf.ChoiceHeld::answer),
/// never inside the answer that told it.
fn PressWait::answered(self : PressWait) -> Unit {
  match self.held {
    Some(h) => {
      // (waiting no more: what it waits for read no more, and nothing else ends it)
      self.waiting = false
      match self.stop {
        Some(stop) => {
          self.stop = None
          @signals.after_flush(stop)
        }
        None => ()
      }
      // (the menu it holds steps on to what it opens apart from the answer that told it: @sf.ChoiceHeld::answer)
      h.answer(fn() { self.still_pressed() }, self.go, self.let_go)
    }
    None => {
      self.end()
      (self.go)()
    }
  }
}

///|
/// Whether what it was pressed in is as it was then, but for the menu it holds (PressWait::still).
fn PressWait::still_pressed(self : PressWait) -> Bool {
  app.nav.top_stay() == self.stay && @sf.last_presented() == self.shown
}

///|
/// Whether it still waits.
pub fn PressWait::waiting(self : PressWait) -> Bool {
  self.waiting
}

///|
/// It waits no more, doing nothing and letting go of nothing: what it waited for is another's now (the same asked
/// again, what it opened holding it), or it was done.
pub fn PressWait::end(self : PressWait) -> Unit {
  self.waiting = false
  // (the menu it held closed for what it opens, which comes in its place)
  match self.held {
    Some(h) => h.close(chosen=true)
    None => ()
  }
  match self.stop {
    Some(stop) => {
      self.stop = None
      // (stopped once the change under way is told: it may be what stops it)
      @signals.after_flush(stop)
    }
    None => ()
  }
}

///|
/// It waits no more and lets go of what it asked (what it was pressed in is gone, or what holds it is): nothing opens.
pub fn PressWait::give_up(self : PressWait) -> Unit {
  guard self.waiting else { return }
  // Closing the held menu can tell the signal graph before end stops the wait.
  self.waiting = false
  // (the menu it held closed unsaid: nothing comes in its place)
  match self.held {
    Some(h) => h.close(chosen=false)
    None => ()
  }
  self.end()
  (self.let_go)()
}

///|
/// Looked at again now (a build that finds what it waits for answered by a source that tells nothing as it changes):
/// gives up where what it was pressed in is gone, else does what it waited for where `ready` says it can. Nothing
/// where it waits no more.
pub fn PressWait::check(self : PressWait) -> Unit {
  guard self.waiting else { return }
  if !@signals.untracked(fn() { self.still() }) {
    self.give_up()
  } else if @signals.untracked(self.ready) {
    self.answered()
  }
}

///|
/// Watches a reactive condition while a presented menu is open; fires `on_fire` once when `pred()` becomes true,
/// and returns a stop closure to dispose the effect when the menu closes.
pub fn watch_while_open(pred : () -> Bool, on_fire : () -> Unit) -> () -> Unit {
  let active = Ref(true)
  let owner = @signals.set_owner(None)
  let stop = @signals.untracked(fn() {
    @signals.effect(fn() {
      guard active.val else { return }
      if pred() {
        active.val = false
        @signals.untracked(on_fire)
      }
    })
  })
  @signals.set_owner(owner) |> ignore
  if !active.val {
    stop()
  }
  fn() {
    active.val = false
    stop()
  }
}
