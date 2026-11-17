///|
/// Settled silent or long holds and pending holds that have already crossed their diagnostic threshold.
pub fn Tester::hold_faults(self : Tester) -> Array[String] {
  self.reads_own()
  match view_tree() {
    Some(tree) => tree.hold_faults()
    None => []
  }
}

///|
/// Serial async reads discovered by holds in the current run.
pub fn Tester::waterfall_faults(self : Tester) -> Array[String] {
  self.reads_own()
  match view_tree() {
    Some(tree) => tree.waterfall_faults()
    None => []
  }
}

///|
/// Creation snapshots read without tracking in the current tree.
pub fn Tester::untracked_read_faults(self : Tester) -> Array[String] {
  self.reads_own()
  match view_tree() {
    Some(tree) => tree.untracked_read_faults()
    None => []
  }
}

///|
// kept across runs: records the current Tester's fan-out, cleared by reset_globals or by disabling the limit
let tester_fanout_faults : Array[String] = []

///|
fn tester_fanout_reset() -> Unit {
  @signals.fanout_limit.val = 0
  @signals.on_fanout.val = None
  tester_fanout_faults.clear()
}

///|
/// Record writes that queue at least `limit` readers. Zero or less disables reporting and drops the recorded writes.
pub fn Tester::set_fanout_limit(self : Tester, limit : Int) -> Unit {
  self.reads_own()
  if limit <= 0 {
    tester_fanout_reset()
    return
  }
  @signals.fanout_limit.val = limit
  @signals.on_fanout.val = Some(fn(loc, count) {
    let place = loc.map(@view.source_place).unwrap_or("<unknown>")
    tester_fanout_faults.push(
      "[FAN_OUT] Signal write at \{place} notified \{count} subscribers (>= \{limit}). " +
      "Fix: isolate per-row reads with View::keyed_by / @signals.keyed_list or selection membership with " +
      "View::selected / @signals.keyed instead of reading a whole list in every item.",
    )
  })
}

///|
/// Writes that met the configured fan-out threshold, in propagation order.
pub fn Tester::fanout_faults(self : Tester) -> Array[String] {
  self.reads_own()
  tester_fanout_faults.copy()
}
