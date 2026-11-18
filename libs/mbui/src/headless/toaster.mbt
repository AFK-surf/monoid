// The toaster: short notices that go by themselves (Radix's Toast, WAI-ARIA's status in a region). Of the toasts its
// caller gives (`toasts`, each by its id: one given again by its id the same toast, saying what it says now) each is a
// node of a region (`Region`, called by `label`), read out politely as it comes (a `Status` called by its title, its
// description its description), and taking a press of its own, the room round them none. Where the region is, how
// wide, and how each toast looks, comes in and goes out is its caller's (`region`, `look`): this is how they live.
//
// Time. Each stays `duration(toast)` ms (as it says now: one saying it stays longer stays that much longer) from the
// moment it is given, then goes by itself (`gone` told its id, once). The time of all of them stops while the pointer
// is over one, or the focus on one's action (`ToastItem::action`), and goes on from what each had left as they leave.
// The moment the next goes by itself and the moment those moving are done are asked by the toaster's key
// (`toaster_due`, `toaster_rest`): what a test runs to, and what a replay waits for.
//
// The hand. A toast held and drawn to the right follows the finger (`ToastItem::dx`, never to the left); let go past a
// third of its width as it would land from the finger's speed (@view.lands_past), or flicked (@view.flung_away), it
// goes (`gone`), else it comes back (dx 0). Its action pressed (the pointer, a key, a screen reader) is taken once and
// it goes (`acted` told its id); a look's own close (Comma's ✕) is `ToastItem::close`, gone as by itself, and holds the
// toasts' time while it has the focus as an action does where the look says so (`ToastItem::holds_focus`). As one goes
// (any of these, or no longer given) it is `live` no more and its time is let go: what is leaving takes no press, drag
// or focus (View::leave), the structure holding it `leave` ms after it is no longer given, for its look's way out.
//
// What moves is its look's: a look that moves a toast (in as it comes, out as it goes) tells the toaster when that way
// is done (`ToastItem::moves`), so `toaster_rest` answers for it too.

///|
/// One toast of a toaster as its look reads it: what it says now, whether it is still there, how far a finger draws it.
/// Each reading followed where a binding reads it.
pub struct ToastItem[T] {
  priv item : @signals.Signal[T]
  priv row : @view.View
  priv dx : @signals.Signal[Double]
  priv live : @signals.Signal[Bool]
  priv focus_in : @signals.Signal[Int]
  priv leave : ((String) -> Unit) -> Unit
  priv acted : (String) -> Unit
  priv gone : (String) -> Unit
  priv rest : Ref[(Double) -> Double]
}

///|
/// What the toast says now (given again by its id: as it is given then).
pub fn[T] ToastItem::toast(self : ToastItem[T]) -> T {
  self.item.get()
}

///|
/// The node its toaster's structure made for it (a row of `View::each`, the toast's own node in it): where its look
/// lays out the room it takes and its way in and out (View::opens, View::leaving), never what takes a press.
pub fn[T] ToastItem::row(self : ToastItem[T]) -> @view.View {
  self.row
}

///|
/// Whether it is still there: not going out (by itself, swiped away, its action taken, closed, or no longer given).
pub fn[T] ToastItem::live(self : ToastItem[T]) -> Bool {
  self.live.get()
}

///|
/// How far (points, 0 or more) a finger draws it to the right now; 0 once let go short, and as it is no longer live
/// (where it goes is its look's).
pub fn[T] ToastItem::dx(self : ToastItem[T]) -> Double {
  self.dx.get()
}

///|
/// Node `a` (in the toast's look) its action, read out a button `label` says, as it says it: pressed, the toast's
/// action taken (once, `acted`) and it goes; the focus on it, the toasts' time stopped. Its node.
pub fn[T] ToastItem::action(self : ToastItem[T], a : @view.View, label : () -> String) -> @view.View {
  let s = self
  a
  .presses(Is(true))
  .focusable(Is(true))
  .says(By(fn() { Some(@view.said(Button, label=label())) }))
  .on_press(fn() { (s.leave)(s.acted) })
  |> ignore
  s.holds_focus(a)
  a
}

///|
/// Node `n` (in the toast's look: its own close, a ✕ the look makes a button of) holds the toasts' time while it has
/// the focus, as the toast's action does; let go with it.
pub fn[T] ToastItem::holds_focus(self : ToastItem[T], n : @view.View) -> Unit {
  hold_while(n, self.focus_in, fn() { n.focused() })
}

///|
/// The toast closed by its look's own (a ✕, a key): it goes as by itself (`gone`, once). Called from a handler.
pub fn[T] ToastItem::close(self : ToastItem[T]) -> Unit {
  (self.leave)(self.gone)
}

///|
/// Its look tells the toaster when the way it moves the toast by is done, as of a moment (-1: none goes): asked by
/// `toaster_rest`, with when the structure lets it go. Said once, as the look is made.
pub fn[T] ToastItem::moves(self : ToastItem[T], rest : (Double) -> Double) -> Unit {
  self.rest.val = rest
}

///|
/// While `on` says so of node `n`, one more holding the toasts' time (`held`), let go with it.
fn hold_while(n : @view.View, held : @signals.Signal[Int], on : () -> Bool) -> Unit {
  let had = Ref(false)
  n.reacts(on, fn(h) {
    if h != had.val {
      had.val = h
      held.set(held.untracked() + (if h { 1 } else { -1 }))
    }
  })
  n.owns(fn() {
    if had.val {
      had.val = false
      held.set(held.untracked() - 1)
    }
  })
  |> ignore
}

///|
/// When what each toast of a toaster does next is due (toaster_due, toaster_rest): by the toast's id, the moment its
/// time is out (-1 while it is stopped or let go) and the moment it is done moving (-1 where it moves no more).
priv struct ToasterTimes {
  rows : Map[String, (() -> Double, () -> Double)]
}

///|
/// The toasters there are, by their key (toaster_due's, toaster_rest's).
// kept across runs: each put as its toaster is made, taken out as it is let go
let toasters : Map[String, ToasterTimes] = Map([])

///|
/// When the next of toaster `key`'s toasts goes by itself (its time out), -1 where none is counting (none, or their
/// time stopped); None where there is no toaster `key`.
pub fn toaster_due(key : String) -> Double? {
  guard toasters.get(key) is Some(t) else { return None }
  let mut due = -1.0
  for _, r in t.rows {
    let d = (r.0)()
    if d >= 0.0 && (due < 0.0 || d < due) {
      due = d
    }
  }
  Some(due)
}

///|
/// When toaster `key`'s toasts are done moving (their looks' ways in and out, and going out, as each is let go), -1
/// where none moves; None where there is no toaster `key`.
pub fn toaster_rest(key : String) -> Double? {
  guard toasters.get(key) is Some(t) else { return None }
  let mut rest = -1.0
  for _, r in t.rows {
    let e = (r.1)()
    if e > rest {
      rest = e
    }
  }
  Some(rest)
}

///|
/// The toasts `toasts` gives (each by its `id`, read out by what `said` says of it: its title and description) as a
/// region in `parent` called `label`: `region` is given the region's node once as it is made (where it is, how wide,
/// how its toasts are laid out in it), and `look` each toast's node and its `ToastItem` once as each is made (all that
/// is drawn of it, how it comes in and goes out). Each stays `duration(toast)` ms (as it says now); `acted` and `gone`
/// told with a toast's id as its action is taken and as it goes otherwise (its time out, swiped away, closed), each
/// once, each its own. A toast no longer given is held `leave` ms for its way out. Its times asked as `key`'s
/// (toaster_due, toaster_rest). The region's node.
#callsite(autofill(loc))
pub fn[T : Eq] toaster(
  parent : @view.View,
  toasts : () -> Array[T],
  id : (T) -> String,
  said : (T) -> (String, String),
  duration : (T) -> Double,
  region : (@view.View) -> Unit,
  look : (@view.View, ToastItem[T]) -> Unit,
  acted : (String) -> Unit,
  gone : (String) -> Unit,
  key? : String = "toast",
  label? : String = "通知",
  leave? : Double = 0.0,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  // (how many hold the time of all of them: the pointer over one, the focus in one)
  let held = @signals.signal(0)
  let times : ToasterTimes = { rows: Map([]) }
  toasters[key] = times
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    v.owns(fn() {
      if toasters.get(key) is Some(t) && physical_equal(t, times) {
        toasters.remove(key)
      }
    })
    |> ignore
    region(v)
    v.says(Is(Some(@view.said(Region, label~)))) |> ignore
    v.each(
      toasts,
      id,
      fn(row, item) { toast_lives(row, item, id, said, duration, held, times, look, acted, gone, loc) },
      leave~,
    )
  })
}

///|
/// Toast `item` in `row` (toaster's): its time, its hold, its swipe, what it is read out as; its node in `row`, built by
/// `look`.
fn[T] toast_lives(
  row : @view.View,
  item : @signals.Signal[T],
  id_of : (T) -> String,
  said : (T) -> (String, String),
  duration : (T) -> Double,
  held : @signals.Signal[Int],
  times : ToasterTimes,
  look : (@view.View, ToastItem[T]) -> Unit,
  acted : (String) -> Unit,
  gone : (String) -> Unit,
  loc : SourceLoc,
) -> Unit {
  let id = @signals.untracked(fn() { id_of(item.get()) })
  let live = @signals.signal(true)
  let dx = @signals.signal(0.0)
  let focus_in = @signals.signal(0)
  // its time: how long it stays (as it says now), what is left of it while it is stopped, when it is out while it
  // counts (None: stopped: one moment kept, not worked out again as nothing changes), its wake (let go as it stops, as
  // it goes)
  let stays = Ref(@signals.untracked(fn() { duration(item.get()) }))
  let left = Ref(stays.val)
  let ends : Ref[Double?] = Ref(None)
  let due : Ref[() -> Unit] = Ref(fn() {  })
  let stop = fn(at : Double) {
    (due.val)()
    due.val = fn() {  }
    match ends.val {
      Some(e) => {
        left.val = e - at
        ends.val = None
      }
      None => ()
    }
  }
  // (going out from this moment: its time let go; told once, its own)
  let leave = fn(f : (String) -> Unit) {
    if live.untracked() {
      live.set(false)
      dx.set(0.0)
      stop(row.cause_at())
      f(id)
    }
  }
  // (the one place its time is counted from: as it is made, as the toasts are held and let go, as it says it stays
  // otherwise, as it goes)
  row.reacts(fn() { (held.get() > 0 || !live.get(), duration(item.get())) }, fn(now) {
    let (stopped, d) = now
    let at = row.cause_at()
    let more = d - stays.val
    stays.val = d
    // (its time on screen: what is shown does not wait for it; toaster_due says it)
    let count = fn(e : Double) {
      (due.val)()
      ends.val = Some(e)
      due.val = row.at_moment(e, fn() { leave(gone) }, later=true)
    }
    match (stopped, ends.val) {
      (true, _) => {
        stop(at)
        left.val = left.val + more
      }
      // (counting on: its moment as it was, moved only by how much longer it says it stays)
      (false, Some(e)) => if more != 0.0 { count(e + more) }
      (false, None) => {
        left.val = left.val + more
        count(at + left.val)
      }
    }
  })
  // (no longer given, it goes; given again by its id as it goes, it is there again, its time from what it had left)
  let was_leaving = Ref(false)
  row.reacts(fn() { row.leaving() }, fn(l) {
    if l && !was_leaving.val {
      live.set(false)
      dx.set(0.0)
    } else if !l && was_leaving.val {
      live.set(true)
    }
    was_leaving.val = l
  })
  let rest : Ref[(Double) -> Double] = Ref(fn(_) { -1.0 })
  // (done, as of the moment the frames are at, when its look's way ends and, going out, as it is let go: the later)
  times.rows[id] = (
    fn() { ends.val.unwrap_or(-1.0) },
    fn() {
      let now = row.logic_at()
      let way = (rest.val)(now)
      let let_go = row.leaves_at()
      if let_go > now && let_go > way {
        let_go
      } else {
        way
      }
    },
  )
  row.owns(fn() {
    (due.val)()
    if times.rows.get(id) is Some(_) {
      times.rows.remove(id)
    }
  })
  |> ignore
  let s : ToastItem[T] = { item, row, dx, live, focus_in, leave, acted, gone, rest }
  row.box(made_for=loc, fn(b) {
    look(b, s)
    b
    .presses(Is(true))
    .says(By(fn() {
      let (title, description) = said(item.get())
      Some(@view.said(Status, label=title, description~))
    }))
    |> ignore
    // (held: the pointer on it (on its action too, nothing over it there) or the focus on its action, one of the
    // toasts holding them all)
    hold_while(b, held, fn() { b.pointed_in() || focus_in.get() > 0 })
    // swiped: followed while held, put away past a third of it (as wide as it is) or quick, else back
    let x0 = Ref(0.0)
    let last = Ref((0.0, 0.0))
    let quick = Ref(0.0)
    b.on_drag(fn(d) {
      match d.kind {
        Down => {
          x0.val = d.x
          last.val = (d.x, d.at)
          quick.val = 0.0
        }
        Moved => {
          dx.set(if d.x - x0.val > 0.0 { d.x - x0.val } else { 0.0 })
          let (lx, lt) = last.val
          if d.at > lt {
            quick.val = (d.x - lx) / (d.at - lt)
          }
          last.val = (d.x, d.at)
        }
        Up =>
          if toast_put_away(d.x - x0.val, d.w, quick.val) {
            leave(gone)
          } else {
            dx.set(0.0)
          }
        Off => dx.set(0.0)
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// Whether a toast `w` wide a finger drew `dx` aside, let go going `quick` (points a ms), is put away: landing past a
/// third of it on from that speed (@view.lands_past), or flicked (@view.flung_away, as a sheet is put away).
fn toast_put_away(dx : Double, w : Double, quick : Double) -> Bool {
  @view.lands_past(dx, quick, w / 3.0) || quick > @view.flung_away
}
