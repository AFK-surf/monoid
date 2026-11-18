// holds.ts: what keeps the station from updating itself for now (updates.ts `toUpdateTo`): work an update would cut
// off and that is not handed over to the next station process, as running turns are. A command run with a vault grant
// is one: its proxy or ssh-agent lives in this process. Once the last hold is let go, an update that waited goes ahead
// (`on_let_go`).

///|
let holds : Map[Int, Unit] = Map([])

///|
let told : Map[Int, () -> Unit] = Map([])

///|
let hold_serial : Ref[Int] = Ref(0)

///|
/// Held while it runs: the returned function lets go (once).
pub fn hold() -> () -> Unit {
  hold_serial.val += 1
  let h = hold_serial.val
  holds[h] = ()
  () => {
    if !holds.contains(h) {
      return
    }
    holds.remove(h)
    if holds.length() > 0 {
      return
    }
    for f in told.values().collect() {
      f()
    }
  }
}

///|
/// How many holds there are now.
pub fn holding() -> Int {
  holds.length()
}

///|
/// `f` called each time the last hold is let go; the returned function stops it.
pub fn on_let_go(f : () -> Unit) -> () -> Unit {
  hold_serial.val += 1
  let id = hold_serial.val
  told[id] = f
  () => told.remove(id)
}
