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
