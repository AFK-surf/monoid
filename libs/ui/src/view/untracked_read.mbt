// A bare read as a box is made keeps a snapshot the graph cannot update. The signal graph calls us only when no
// subscriber reads and the caller did not ask for a snapshot. View::owning suspends this scope for other node work.

///|
// kept across runs: set and put back around each sourced box's make, checked and cleared by the Tester
let making_box : Ref[(Tree, Int, Int)?] = Ref(None)

///|
// kept across runs: set and put back around each sourced view's make (box, structure_box, root), checked and cleared by the Tester
let making_view : Ref[(Tree, Int, Int)?] = Ref(None)

///|
priv struct UntrackedReadLog {
  tree : Tree
  faults : Array[String]
  seen : Map[String, Bool]
  places : Map[String, Array[String]]
  effect_faults : Array[String]
  effect_seen : Map[String, Bool]
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
  let log : UntrackedReadLog = {
    tree: self,
    faults: [],
    seen: Map([]),
    places: Map([]),
    effect_faults: [],
    effect_seen: Map([]),
    unown: fn() {  },
  }
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
fn effect_in_view_made(loc : SourceLoc) -> Unit {
  guard making_view.val is Some((tree, at, gen)) else { return }
  let id : NodeId = { at, gen }
  guard tree.alive_id(id) else { return }
  let log = tree.untracked_read_log()
  let place = source_place(loc)
  guard !log.effect_seen.contains(place) else { return }
  log.effect_seen[place] = true
  let detail = "[EFFECT_IN_VIEW] Bare @signals.effect created while constructing a View node at \{place}; " +
    "bare effects do not rest when the node is parked. Fix: use View::reacts, Live::By(fn() { ... }), or View::owns."
  log.effect_faults.push(detail)
}

///|
fn View::make_with_effect_diagnostics(self : View, make : (View) -> Unit) -> Unit {
  let effect_hook = @signals.on_effect_in_view.val
  @signals.on_effect_in_view.val = Some(effect_in_view_made)
  let making = making_view.val
  making_view.val = Some((self.tree, self.at, self.gen))
  make(self)
  making_view.val = making
  @signals.on_effect_in_view.val = effect_hook
}

///|
fn View::make_with_read_diagnostics(self : View, make : (View) -> Unit) -> Unit {
  let hook = @signals.on_untracked_read.val
  let effect_hook = @signals.on_effect_in_view.val
  @signals.on_untracked_read.val = Some(untracked_box_read)
  @signals.on_effect_in_view.val = Some(effect_in_view_made)
  let making = making_box.val
  let making_v = making_view.val
  making_box.val = Some((self.tree, self.at, self.gen))
  making_view.val = Some((self.tree, self.at, self.gen))
  make(self)
  making_box.val = making
  making_view.val = making_v
  @signals.on_untracked_read.val = hook
  @signals.on_effect_in_view.val = effect_hook
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
/// Bare `@signals.effect` calls observed while constructing nodes on this tree, in the order first observed.
pub fn Tree::effect_in_view_faults(self : Tree) -> Array[String] {
  match find_untracked_read_log(self) {
    Some(log) => log.effect_faults.copy()
    None => []
  }
}

///|
fn count_scroll_each_in(
  tree : Tree,
  at : Int,
  scroll_at : Int,
  limit : Int,
  out : Array[String],
) -> Unit {
  guard at >= 0 && at < tree.nodes.length() else { return }
  let n = tree.nodes[at]
  guard n.live else { return }
  if at != scroll_at && tree.scrolls_at.contains(at) {
    return
  }
  if n.slot {
    let mut rows = 0
    for k in n.kids {
      if k >= 0 && k < tree.nodes.length() && tree.nodes[k].live && tree.nodes[k].each_row {
        rows += 1
      }
    }
    if rows > limit {
      let place = match n.source {
        Some(s) =>
          match s.made_for {
            Some(mf) => " at " + source_place(s.made) + " (for " + source_place(mf) + ")"
            None => " at " + source_place(s.made)
          }
        None => {
          let sid : NodeId = { at: scroll_at, gen: tree.nodes[scroll_at].gen }
          match tree.sources_of(sid).get(0) {
            Some(first) => " at " + first.made
            None => ""
          }
        }
      }
      out.push(
        "[UNVIRTUALIZED_SCROLL_EACH] View::each inside non-virtualized View::scrolls\{place} renders \{rows} live items (> \{limit}). " +
        "Fix: use View::list_reused or View::scrolls_reused for large scrollable lists.",
      )
    }
  }
  for k in n.kids {
    count_scroll_each_in(tree, k, scroll_at, limit, out)
  }
}

///|
/// Non-virtualized `View::scrolls` containers whose descendant `View::each` renders more than `limit` live items.
/// Virtualized lists (`View::scrolls_window`, `View::scrolls_reused`, `View::list_reused`) are excluded.
pub fn Tree::scroll_each_faults(self : Tree, limit? : Int = 50) -> Array[String] {
  if limit <= 0 {
    return []
  }
  let out : Array[String] = []
  for scroll_at, s in self.scrolls_at {
    if scroll_at < 0 || scroll_at >= self.nodes.length() || !self.nodes[scroll_at].live {
      continue
    }
    if s.whole is Some(_) {
      continue
    }
    let held_at = self.nodes[scroll_at].scroll_held
    if held_at >= 0 && held_at < self.nodes.length() && self.nodes[held_at].live {
      count_scroll_each_in(self, held_at, scroll_at, limit, out)
    }
  }
  out
}

///|
/// Whether a box's make context is still open.
pub fn untracked_read_marks_left() -> Bool {
  making_box.val is Some(_) || making_view.val is Some(_)
}

///|
/// Clear creation-read diagnostics at the beginning of a new run.
pub fn untracked_read_reset() -> Unit {
  making_box.val = None
  making_view.val = None
  @signals.on_untracked_read.val = None
  @signals.on_effect_in_view.val = None
  while untracked_read_logs.pop() is Some(log) {
    (log.unown)()
    log.unown = fn() {  }
  }
}
