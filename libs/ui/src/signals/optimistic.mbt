///|
/// An authoritative value projected through ordered pending edits.
pub struct Optimistic[T] {
  priv edits : Array[Ref[((T) -> T)?]]
  priv revision : Signal[Int64]
  priv value : Computed[T]
  priv pending : Computed[Bool]
}

///|
/// Follow authority with value equality. A pending edit is a pure transform of the value preceding it.
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
#callsite(autofill(loc))
pub fn[T : Eq] optimistic(
  authority : () -> T,
  same? : (T, T) -> Bool,
  loc~ : SourceLoc,
) -> Optimistic[T] {
  optimistic_by(authority, same=same.unwrap_or(same_value), loc~)
}

///|
/// Follow the projected value by reference identity.
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
#callsite(autofill(loc))
pub fn[T] optimistic_ref(authority : () -> T, loc~ : SourceLoc) -> Optimistic[T] {
  optimistic_by(authority, same=same_ref, loc~)
}

///|
/// Follow the projected value using `same`.
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
#callsite(autofill(loc))
pub fn[T] optimistic_by(
  authority : () -> T,
  same~ : (T, T) -> Bool,
  loc~ : SourceLoc,
) -> Optimistic[T] {
  let edits : Array[Ref[((T) -> T)?]] = []
  let revision = signal(0L)
  let value = computed_by(
    fn(_) {
      revision.get() |> ignore
      let mut projected = authority()
      for entry in edits {
        if entry.val is Some(apply) {
          projected = apply(projected)
        }
      }
      projected
    },
    same~,
    loc~,
  )
  let pending = computed(
    fn(_) {
      revision.get() |> ignore
      !edits.is_empty()
    },
    loc~,
  )
  { edits, revision, value, pending }
}

///|
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
pub fn[T] Optimistic::get(self : Optimistic[T]) -> T {
  self.value.get_releasing()
}

///|
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
pub fn[T] Optimistic::untracked(self : Optimistic[T]) -> T {
  self.value.untracked_releasing()
}

///|
/// True while at least one edit is pending, independent of any read of authority.
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
pub fn[T] Optimistic::is_pending(self : Optimistic[T]) -> Bool {
  self.pending.get()
}

///|
fn[T] Optimistic::changed(self : Optimistic[T], loc : SourceLoc) -> Unit {
  // Advance from the last write without pulling an intermediate batch value.
  self.revision.set(self.revision.1.pending + 1L, loc~)
}

///|
/// Add an edit and return its idempotent removal. On success batch the authority update and the removal together.
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
#callsite(autofill(loc))
pub fn[T] Optimistic::push(self : Optimistic[T], apply : (T) -> T, loc~ : SourceLoc) -> () -> Unit {
  let entry = Ref(Some(apply))
  self.edits.push(entry)
  self.changed(loc)
  fn() {
    if entry.val is Some(_) {
      for i, pending in self.edits {
        if physical_equal(pending, entry) {
          entry.val = None
          self.edits.remove(i) |> ignore
          let empty_edit : Ref[((T) -> T)?] = Ref(None)
          self.edits.release_unused(placeholder=empty_edit)
          self.changed(loc)
          break
        }
      }
    }
  }
}

///|
/// Add an edit that replaces the projected value.
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
#callsite(autofill(loc))
pub fn[T] Optimistic::set_value(self : Optimistic[T], value : T, loc~ : SourceLoc) -> () -> Unit {
  self.push(fn(_) { value }, loc~)
}

///|
/// Remove every pending edit. Their removal functions become no-ops.
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
pub fn[T] Optimistic::clear(self : Optimistic[T]) -> Unit {
  if self.edits.is_empty() {
    return
  }
  for entry in self.edits {
    entry.val = None
  }
  self.edits.clear()
  let empty_edit : Ref[((T) -> T)?] = Ref(None)
  self.edits.release_unused(placeholder=empty_edit)
  self.changed(self.value.made_at())
}
