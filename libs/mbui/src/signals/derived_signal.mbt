///|
/// A writable computed. A local value lasts until its getter next produces a different upstream value.
pub struct DerivedSignal[T] {
  priv upstream : Computed[(Int64, T)]
  priv value : Computed[T]
  priv written : Ref[(Int64, T)?]
}

///|
/// Follow the getter by value. It receives the last upstream value, including while a local write is visible.
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
#callsite(autofill(loc))
pub fn[T : Eq] derived_signal(
  getter : (T?) -> T,
  same? : (T, T) -> Bool,
  loc~ : SourceLoc,
) -> DerivedSignal[T] {
  derived_signal_by(getter, same=same.unwrap_or(same_value), loc~)
}

///|
/// Follow the getter by reference identity.
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
#callsite(autofill(loc))
pub fn[T] derived_signal_ref(getter : (T?) -> T, loc~ : SourceLoc) -> DerivedSignal[T] {
  derived_signal_by(getter, same=same_ref, loc~)
}

///|
/// Use `same` for both upstream changes and changes of the effective value.
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
#callsite(autofill(loc))
pub fn[T] derived_signal_by(
  getter : (T?) -> T,
  same~ : (T, T) -> Bool,
  loc~ : SourceLoc,
) -> DerivedSignal[T] {
  let written : Ref[(Int64, T)?] = Ref(None)
  let upstream = computed_by(
    fn(last) {
      match last {
        None => (0L, getter(None))
        Some((up_rev, before)) => {
          let next = getter(Some(before))
          if same(before, next) {
            (up_rev, next)
          } else {
            written.val = None
            (up_rev + 1L, next)
          }
        }
      }
    },
    same=fn(a, b) { a.0 == b.0 },
    loc~,
  )
  let value = computed_by(
    fn(_) {
      let base = upstream.get()
      derived_value(base, written.val)
    },
    same~,
    loc~,
  )
  { upstream, value, written }
}

///|
fn[T] derived_value(base : (Int64, T), written : (Int64, T)?) -> T {
  match written {
    Some((rev, local_value)) if rev == base.0 => local_value
    _ => base.1
  }
}

///|
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
pub fn[T] DerivedSignal::get(self : DerivedSignal[T]) -> T {
  self.value.get_releasing()
}

///|
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
pub fn[T] DerivedSignal::untracked(self : DerivedSignal[T]) -> T {
  self.value.untracked_releasing()
}

///|
/// The last worked-out value or local write, without pulling changes from upstream.
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
pub fn[T] DerivedSignal::peek(self : DerivedSignal[T]) -> T? {
  match self.written.val {
    Some((_, value)) => Some(value)
    None => self.value.peek()
  }
}

///|
/// Anchor the write to the upstream value as of this call, even in the middle of a batch.
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
#callsite(autofill(loc))
pub fn[T] DerivedSignal::set(self : DerivedSignal[T], value : T, loc~ : SourceLoc) -> Unit {
  // Pull upstream alone so this write and pending upstream changes are still compared as one by readers.
  let base = self.upstream.untracked_releasing()
  let node = self.value.0
  // The pull may have reached a resource through a cached one-off read of the projection.
  release_unwatched_resource(node)
  let before = derived_value(base, self.written.val)
  if !(self.value.1.same)(before, value) {
    self.written.val = Some((base.0, value))
    node.flags = node.flags | DIRTY
    tell_set(node, loc)
  }
}

///|
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
pub fn[T] DerivedSignal::watched(self : DerivedSignal[T]) -> Bool {
  self.value.watched()
}

///|
/// Release dependencies. The next read establishes them again.
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
pub fn[T] DerivedSignal::dispose(self : DerivedSignal[T]) -> Unit {
  self.value.dispose()
  if !self.upstream.watched() {
    self.upstream.dispose()
  }
}

///|
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
pub fn[T] DerivedSignal::made_at(self : DerivedSignal[T]) -> SourceLoc {
  self.value.made_at()
}
