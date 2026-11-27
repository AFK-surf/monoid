// A node-owned memoized derivation (`View::memo`): shares a computed value across bindings on and under a node so the
// same frame computes it once, stops downstream propagation when equal (`Eq` or `same`), disposes automatically with
// the node, and preserves `Tree::clock_read_now` tracking (e.g. for `View::alpha`).

///|
/// A memoized derivation owned by `self` (`View::owns`): evaluates `f` at most once per change of its dependencies,
/// stops propagating when equal (`same`, defaulting to `==`), disposes when `self` leaves, and forwards
/// `clock_read_now` so callers like `View::alpha` keep accurate animation-clock tracking.
#callsite(autofill(loc))
pub fn[T : Eq] View::memo(
  self : View,
  f : () -> T,
  same? : (T, T) -> Bool,
  loc~ : SourceLoc,
) -> () -> T {
  let tree = self.tree
  let read_clock = Ref(false)
  let prev_read_clock = Ref(false)
  let eq = match same {
    Some(s) => s
    None => fn(a, b) { a == b }
  }
  let c = @signals.computed(
    loc~,
    same=fn(a : T, b : T) { prev_read_clock.val == read_clock.val && eq(a, b) },
    fn(_) {
      let prev = tree.clock_read_now
      tree.clock_read_now = false
      let v = f()
      let read = tree.clock_read_now
      prev_read_clock.val = read_clock.val
      read_clock.val = read
      tree.clock_read_now = prev || read
      v
    },
  )
  self.owns(fn() { c.dispose() }) |> ignore
  fn() {
    let v = c.get()
    if read_clock.val {
      tree.clock_read_now = true
    }
    v
  }
}
