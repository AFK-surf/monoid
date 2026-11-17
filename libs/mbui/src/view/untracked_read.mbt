// A bare read as a box is made keeps a snapshot the graph cannot update. The signal graph calls us only when no
// subscriber reads and the caller did not ask for a snapshot. View::owning suspends this scope for other node work.

///|
// kept across runs: set and put back around each sourced box's make, checked and cleared by the Tester
let making_box : Ref[(Tree, Int, Int)?] = Ref(None)

///|
priv struct UntrackedReadLog {
  tree : Tree
  faults : Array[String]
  seen : Map[String, Bool]
  places : Map[String, Array[String]]
  mut unown : () -> Unit
}

///|
// kept across runs: each tree owns its log until disposal; the Tester resets any remaining logs
let untracked_read_logs : Array[UntrackedReadLog] = []

///|
// kept across runs: source packages declare their legacy limits once, like clock_read_known
let untracked_read_bars : Map[String, Int] = Map([])

///|
/// The remaining places in each source file allowed to read a creation snapshot implicitly. These counts only fall.
pub fn untracked_read_known(bars : Array[(String, Int)]) -> Unit {
  for (file, count) in bars {
    if count > 0 {
      untracked_read_bars[file] = count
    } else {
      untracked_read_bars.remove(file)
    }
  }
}

///|
/// `found` holds distinct places already seen in this file. Test files can exercise the diagnostic at any count.
pub fn untracked_read_fault(place : String, found : Array[String], detail : String) -> String? {
  let file = place_file(place)
  guard !test_file(file) else { return None }
  let count = if found.contains(place) { found.length() } else { found.length() + 1 }
  if count > untracked_read_bars.get(file).unwrap_or(0) { Some(detail) } else { None }
}

///|
fn find_untracked_read_log(tree : Tree) -> UntrackedReadLog? {
  untracked_read_logs.iter().find_first(fn(log) { physical_equal(log.tree, tree) })
}

///|
fn Tree::untracked_read_log(self : Tree) -> UntrackedReadLog {
  if find_untracked_read_log(self) is Some(log) {
    return log
  }
  let log : UntrackedReadLog = { tree: self, faults: [], seen: Map([]), places: Map([]), unown: fn() {  } }
  untracked_read_logs.push(log)
  log.unown = self.root().owns_while(fn() {
    if untracked_read_logs.search_by(fn(it) { physical_equal(it, log) }) is Some(i) {
      untracked_read_logs.remove(i) |> ignore
    }
    log.unown = fn() {  }
  })
  log
}

///|
fn untracked_box_read(_dep : @signals.ReactiveNode) -> Unit {
  guard making_box.val is Some((tree, at, gen)) else { return }
  let id : NodeId = { at, gen }
  guard tree.alive_id(id) && tree.nodes[at].source is Some(_) else { return }
  guard tree.sources_of(id).get(0) is Some(first) else { return }
  let log = tree.untracked_read_log()
  let key = first.made + " for " + first.made_for
  guard !log.seen.contains(key) else { return }
  let part = if first.made_for == "" { "" } else { " (for " + first.made_for + ")" }
  let detail = "[STRICT_READ_UNTRACKED] Reactive value was read with .get() without tracking while making node at \{first.made}\{part}; " +
    "later changes will not update this node. Fix: wrap reactive reads in Live::By(fn() { ... }), View::reacts, " +
    "or a structure condition (View::show/pick/each), or call .untracked() if a one-time creation snapshot is intended."
  log.seen[key] = true
  log.faults.push(detail)
  let file = place_file(first.made)
  let found = log.places.get_or_init(file, fn() { [] })
  if untracked_read_fault(first.made, found, detail) is Some(said) {
    tree.fault(id, said)
  }
  if !found.contains(first.made) {
    found.push(first.made)
  }
}

///|
fn View::make_with_read_diagnostics(self : View, make : (View) -> Unit) -> Unit {
  let hook = @signals.on_untracked_read.val
  @signals.on_untracked_read.val = Some(untracked_box_read)
  let making = making_box.val
  making_box.val = Some((self.tree, self.at, self.gen))
  make(self)
  making_box.val = making
  @signals.on_untracked_read.val = hook
}

///|
/// Creation snapshots read without tracking, in the order first observed on this tree.
pub fn Tree::untracked_read_faults(self : Tree) -> Array[String] {
  match find_untracked_read_log(self) {
    Some(log) => log.faults.copy()
    None => []
  }
}

///|
/// Whether a box's make context is still open.
pub fn untracked_read_marks_left() -> Bool {
  making_box.val is Some(_)
}

///|
/// Clear creation-read diagnostics at the beginning of a new run.
pub fn untracked_read_reset() -> Unit {
  making_box.val = None
  @signals.on_untracked_read.val = None
  while untracked_read_logs.pop() is Some(log) {
    (log.unown)()
    log.unown = fn() {  }
  }
}
