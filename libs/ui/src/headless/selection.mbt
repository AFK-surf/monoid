// Selection model: pure headless state transitions for single and multiple selection with anchor memory (toggle,
// contiguous range selection skipping disabled items, select all, clear). Nothing here is drawn, laid out or read out.

///|
/// Headless selection state calculator with anchor tracking for range selection.
pub struct SelectionModel[K] {
  priv multiple : Bool
  priv anchor_ref : Ref[K?]
}

///|
/// A new selection model (`multiple=false` for single-select, `multiple=true` for multi-select with range/select-all).
pub fn[K] SelectionModel::new(multiple? : Bool = false) -> SelectionModel[K] {
  { multiple, anchor_ref: Ref(None) }
}

///|
/// The current anchor key for range selection, if any.
pub fn[K] SelectionModel::anchor(self : SelectionModel[K]) -> K? {
  self.anchor_ref.val
}

///|
/// Set or clear the anchor key used as the start of range selection.
pub fn[K] SelectionModel::set_anchor(self : SelectionModel[K], key : K?) -> Unit {
  self.anchor_ref.val = key
}

///|
/// Toggle `key` against `current` and update the anchor to `Some(key)`. In single-select mode, returns `[key]`; in
/// multi-select mode, removes `key` if present or appends it otherwise.
pub fn[K : Eq] SelectionModel::toggle(self : SelectionModel[K], current : Array[K], key : K) -> Array[K] {
  self.anchor_ref.val = Some(key)
  if !self.multiple {
    return [key]
  }
  if current.contains(key) {
    current.filter(fn(x) { x != key })
  } else {
    current + [key]
  }
}

///|
/// Select the contiguous range of non-disabled keys in `keys` from the current `anchor` to `to`. When `multiple` is
/// false or no anchor is present in `keys`, sets the anchor to `to` and selects `[to]` (unless disabled). Preserves
/// the existing anchor when extending or shrinking a multi-select range.
pub fn[K : Eq] SelectionModel::select_range(
  self : SelectionModel[K],
  keys : Array[K],
  current : Array[K],
  to : K,
  disabled? : (K) -> Bool = fn(_) { false },
) -> Array[K] {
  if !self.multiple {
    self.anchor_ref.val = Some(to)
    return if disabled(to) { current } else { [to] }
  }
  guard keys.search(to) is Some(to_idx) else { return current }
  let anchor_idx = match self.anchor_ref.val {
    Some(a) => keys.search(a)
    None => None
  }
  match anchor_idx {
    None => {
      self.anchor_ref.val = Some(to)
      if disabled(to) {
        current
      } else {
        [to]
      }
    }
    Some(from_idx) => {
      let (lo, hi) = if from_idx <= to_idx { (from_idx, to_idx) } else { (to_idx, from_idx) }
      let out : Array[K] = []
      for i in lo..<=hi {
        let k = keys[i]
        if !disabled(k) {
          out.push(k)
        }
      }
      out
    }
  }
}

///|
/// Select all non-disabled keys in `keys` (returns empty in single-select mode).
pub fn[K] SelectionModel::select_all(
  self : SelectionModel[K],
  keys : Array[K],
  disabled? : (K) -> Bool = fn(_) { false },
) -> Array[K] {
  if !self.multiple {
    return []
  }
  keys.filter(fn(k) { !disabled(k) })
}

///|
/// Clear selection and reset the anchor.
pub fn[K] SelectionModel::clear(self : SelectionModel[K]) -> Array[K] {
  self.anchor_ref.val = None
  []
}
