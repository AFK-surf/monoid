// What a card, a panel or a sheet waits for before it comes in (OpenGate): opened the first time, what it holds is made
// at once, but what it shows may be the core's still to answer though the device holds it (a topic read as it is made,
// none of its value said yet, the core not saying it waits on a station), or a picture the device holds not decoded
// yet. Coming in then, it came in on its bones and grew to what it holds a moment later. So what it holds is made as
// ever (what it reads asked then, held as it is), and what it comes in by (its way in, its scrim) stays at its start,
// nothing of it seen, till all it waits for is told (each a reaction, at the moment of the answer that tells it) or
// open_hold_ms has gone by since it opened, whichever comes first; then it comes in, from there, whole. Where nothing
// is waited for as it is made (what it holds the device's already, a value kept and shown again at once, nothing
// read), it comes in at the moment it opened, as it did before there was a gate. The library knows nothing of the core:
// what is waited for is told by what reads it as it is made in the gate (open_gate_note, by sfbase's Source::topic),
// a picture by open_gate_picture.

///|
/// How long at most a card, a panel or a sheet waits for what it shows before it comes in as it is (OpenGate): the
/// core reads what the device holds in a few milliseconds, so this is for a core busy at that moment, never for a
/// station (what waits on one is said so and not waited for).
pub let open_hold_ms : Double = 120.0

///|
/// What one card, panel or sheet waits for before it comes in (see the file's head), and what comes in once it does.
pub struct OpenGate {
  priv conds : Array[() -> Bool]
  /// what it holds made: what it waits for all said
  priv mut made_all : Bool
  /// what it holds was made in (its wait's: let go with it)
  priv mut node : @view.View?
  /// its way in, asked before what it holds was made: done as that is
  priv mut pending : (@view.View, () -> Unit)?
  /// it came in (or was let in): what is asked again comes in at once
  priv mut through : Bool
  /// what calls its wait off (its open_hold_ms, its reaction)
  priv mut stop : () -> Unit
  /// whether it waits now (what reads it: a panel taking no press meanwhile)
  priv holding : @signals.Signal[Bool]
}

///|
/// A gate of its own, waiting for nothing yet.
pub fn OpenGate::new() -> OpenGate {
  {
    conds: [],
    made_all: false,
    node: None,
    pending: None,
    through: false,
    stop: fn() {  },
    holding: @signals.signal(false, same=fn(a, b) { a == b }),
  }
}

///|
/// The gates whose content is being made now, innermost last: what is read as it is made is waited for by the last.
// kept across runs: emptied as a run begins (open_gate_reset), each made and taken off within one call (collect)
let open_gates : Array[OpenGate] = []

///|
fn init {
  @ui.on_reset(fn() { open_gates.clear() })
}

///|
/// What `make` makes, made in the gate: what it reads as it makes it (open_gate_note) is waited for by it.
pub fn OpenGate::collect(self : OpenGate, make : () -> Unit) -> Unit {
  open_gates.push(self)
  make()
  // (taken off whatever `make` did: the gate on top is this one)
  match open_gates.search_by(fn(g) { physical_equal(g, self) }) {
    Some(i) => open_gates.truncate(i)
    None => ()
  }
}

///|
/// Whether something is being made in a gate now: what reads a topic as it is made tells it (open_gate_note).
pub fn open_gate_collecting() -> Bool {
  !open_gates.is_empty()
}

///|
/// What is made in the gate now waits for `ready` (read where it is read, followed): a topic's value or why not said,
/// or that it waits on a station.
pub fn open_gate_note(ready : () -> Bool) -> Unit {
  match open_gates.last() {
    Some(g) if !g.made_all => g.conds.push(ready)
    _ => ()
  }
}

///|
/// What is made in the gate now shows picture `key` (an image's key, "" none): waited for where the device holds it
/// and has not decoded it yet (as the first page waits for its pictures: the host's word on it).
pub fn open_gate_picture(key : String) -> Unit {
  if key != "" && open_gate_collecting() && @ui.has_image(key) && !@ui.image_any_ready(key) {
    open_gate_note(fn() { @ui.image_any_ready(key) })
  }
}

///|
/// Whether it waits now (followed): what it comes in by stays at its start meanwhile.
pub fn OpenGate::holding(self : OpenGate) -> Bool {
  self.holding.get()
}

///|
/// What it holds made, in node `n` (what its wait is kept by, let go with it): what it waits for said. A way in asked
/// before is done now, or once it waits no more (OpenGate::go).
pub fn OpenGate::seal(self : OpenGate, n : @view.View) -> Unit {
  self.made_all = true
  self.node = Some(n)
  match self.pending {
    Some((n, go)) => {
      self.pending = None
      self.go(n, go)
    }
    None => ()
  }
}

///|
/// `go` (what sets its way in off, from node `v`'s cause's moment) done now where it waits for nothing (or has come in
/// already), else at the moment all it waits for is told or open_hold_ms after now, whichever comes first, once. Asked
/// before what it holds is made (OpenGate::seal), kept for then.
pub fn OpenGate::go(self : OpenGate, v : @view.View, go : () -> Unit) -> Unit {
  if !self.made_all {
    self.pending = Some((v, go))
    return
  }
  (self.stop)()
  self.stop = fn() {  }
  if self.through || self.conds.is_empty() || @signals.untracked(fn() { self.conds.iter().all(fn(c) { c() }) }) {
    self.through = true
    self.holding.set(false)
    go()
    return
  }
  self.holding.set(true)
  let v = self.node.unwrap_or(v)
  let done = @signals.signal(false, same=fn(a, b) { a == b })
  // (called off: what it waited for coming after that lets nothing in)
  let off = Ref(false)
  let stops : Array[() -> Unit] = []
  let pass = fn() {
    guard !off.val && !self.through else { return }
    self.through = true
    for s in stops {
      s()
    }
    self.stop = fn() {  }
    self.holding.set(false)
    // (what it waited for read no more: the reaction let go of it)
    done.set(true)
    go()
  }
  stops.push(v.at_moment(v.cause_at() + open_hold_ms, pass))
  v.reacts(
    fn() { done.get() || self.conds.iter().all(fn(c) { c() }) },
    at_start=false,
    fn(ok) {
      if ok {
        pass()
      }
    },
  )
  self.stop = fn() {
    off.val = true
    for s in stops {
      s()
    }
    // (called off: what it waited for read no more)
    if !done.untracked() {
      done.set(true)
    }
  }
}

///|
/// Its wait called off (closed while it waited: it goes as it is, nothing of it seen); a way in asked and not done
/// forgotten.
pub fn OpenGate::stop(self : OpenGate) -> Unit {
  self.pending = None
  (self.stop)()
  self.stop = fn() {  }
  self.holding.set(false)
}
