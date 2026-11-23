// Reorder and cross-container transfer: pointer-drag and keyboard-accessible reordering within a single list
// (`Reorder[K]`) and across multiple containers (`Transfer[C, K]`, e.g. kanban columns). Controlled by caller
// callbacks (`on_commit`, `on_transfer`); nothing here is drawn, laid out or read out.

///|
/// Active reorder state for a single list: the moving item's key, its origin index, its current target index, and
/// whether the reorder was started via the keyboard.
#derive(Eq, Debug)
pub(all) struct ReorderDraft[K] {
  key : K
  from_index : Int
  to_index : Int
  by_keyboard : Bool
}

///|
/// Single-list reorder controller supporting both pointer drag (with slop gating and edge-scroll speed helper) and
/// keyboard-accessible grab/move/commit/cancel.
pub struct Reorder[K] {
  priv keys : () -> Array[K]
  priv on_commit : (K, Int, Int) -> Unit
  priv axis : GroupAxis
  priv slop : Double
  priv off : () -> Bool
  priv draft : @signals.Signal[ReorderDraft[K]?]
  priv pending : Ref[(K, Int, Double)?]
}

///|
/// Create a new `Reorder[K]` controller for a list whose current item order is returned by `keys`. Committing a move
/// calls `on_commit(key, from_index, to_index)`. Pointer drags wait until movement reaches `slop` along `axis`.
pub fn[K : Eq] Reorder::new(
  keys : () -> Array[K],
  on_commit : (K, Int, Int) -> Unit,
  axis? : GroupAxis = Vertical,
  slop? : Double = 4.0,
  disabled? : () -> Bool = fn() { false },
) -> Reorder[K] {
  {
    keys,
    on_commit,
    axis,
    slop,
    off: disabled,
    draft: @signals.signal(None),
    pending: Ref(None),
  }
}

///|
/// The current active reorder draft, if any. Tracked when read inside a binding.
pub fn[K] Reorder::active(self : Reorder[K]) -> ReorderDraft[K]? {
  self.draft.get()
}

///|
/// Whether `key` is currently being reordered. Tracked when read inside a binding.
pub fn[K : Eq] Reorder::is_dragging(self : Reorder[K], key : K) -> Bool {
  match self.draft.get() {
    Some(d) => d.key == key
    None => false
  }
}

///|
/// The current target drop index while a reorder is active, or `None`. Tracked when read inside a binding.
pub fn[K] Reorder::drop_index(self : Reorder[K]) -> Int? {
  match self.draft.get() {
    Some(d) => Some(d.to_index)
    None => None
  }
}

///|
/// Begin a pointer drag on `key` at `pointer_pos` along the list axis. If `slop > 0.0`, the drag stays pending until
/// `move_drag` moves at least `slop` points away from `pointer_pos`.
pub fn[K : Eq] Reorder::start_drag(self : Reorder[K], key : K, pointer_pos : Double) -> Unit {
  if (self.off)() {
    return
  }
  let ks = (self.keys)()
  guard ks.search(key) is Some(idx) else { return }
  if self.slop <= 0.0 {
    self.pending.val = None
    self.draft.set(Some({ key, from_index: idx, to_index: idx, by_keyboard: false }))
  } else {
    self.pending.val = Some((key, idx, pointer_pos))
    self.draft.set(None)
  }
}

///|
/// Compute the target drop index for `pointer_pos` given the item center coordinates `item_centers` and list length
/// `count`. Picks the item whose center is nearest to `pointer_pos`, clamped to `0..<count`.
fn reorder_target_index(pointer_pos : Double, item_centers : Array[Double], count : Int, fallback : Int) -> Int {
  let n = item_centers.length()
  if n == 0 || count <= 0 {
    return fallback
  }
  let limit = if n < count { n } else { count }
  let mut best_i = 0
  let mut best_d = (pointer_pos - item_centers[0]).abs()
  for i in 1..<limit {
    let d = (pointer_pos - item_centers[i]).abs()
    if d < best_d {
      best_d = d
      best_i = i
    }
  }
  best_i
}

///|
/// Advance an active (or pending) pointer drag to `pointer_pos`, updating `to_index` against `item_centers`.
pub fn[K] Reorder::move_drag(self : Reorder[K], pointer_pos : Double, item_centers : Array[Double]) -> Unit {
  if (self.off)() {
    self.cancel()
    return
  }
  let ks = (self.keys)()
  let n = ks.length()
  match self.draft.untracked() {
    Some(d) => {
      let next_idx = reorder_target_index(pointer_pos, item_centers, n, d.to_index)
      if next_idx != d.to_index {
        self.draft.set(Some({ ..d, to_index: next_idx }))
      }
    }
    None =>
      match self.pending.val {
        Some((key, from_index, start_pos)) =>
          if (pointer_pos - start_pos).abs() >= self.slop {
            self.pending.val = None
            let to_index = reorder_target_index(pointer_pos, item_centers, n, from_index)
            self.draft.set(Some({ key, from_index, to_index, by_keyboard: false }))
          }
        None => ()
      }
  }
}

///|
/// Commit the active reorder, calling `on_commit(key, from_index, to_index)` when the item moved to a different index,
/// and exit the active state.
pub fn[K] Reorder::commit(self : Reorder[K]) -> Unit {
  self.pending.val = None
  match self.draft.untracked() {
    Some(d) => {
      self.draft.set(None)
      if !(self.off)() && d.from_index != d.to_index {
        (self.on_commit)(d.key, d.from_index, d.to_index)
      }
    }
    None => ()
  }
}

///|
/// Cancel any active or pending reorder without calling `on_commit`.
pub fn[K] Reorder::cancel(self : Reorder[K]) -> Unit {
  self.pending.val = None
  self.draft.set(None)
}

///|
/// Edge auto-scroll speed (points per ms) for `pointer_pos` inside a viewport spanning `[start, end]` along the list
/// axis, delegating to `edge_scroll_speed`. Returns `0.0` when no reorder is active.
pub fn[K] Reorder::scroll_speed(
  self : Reorder[K],
  pointer_pos : Double,
  start : Double,
  end : Double,
  zone? : Double = 40.0,
  max_speed? : Double = 0.6,
) -> Double {
  match self.draft.get() {
    Some(_) => edge_scroll_speed(pointer_pos, start, end, zone~, max_speed~)
    None => 0.0
  }
}

///|
/// Bind keyboard-accessible reordering onto item node `v` for `key`:
/// - `Space` grabs the focused item (`from_index`, `to_index = from_index`, `by_keyboard = true`);
/// - Arrow keys along `axis` (respecting `rtl`) move `to_index` by -1/+1, `Home`/`End` jump to first/last;
/// - `Space` or `Enter` commits (`on_commit`) and exits grabbed state;
/// - `Escape` cancels without committing.
pub fn[K : Eq] Reorder::item(
  self : Reorder[K],
  v : @view.View,
  key : K,
  rtl? : Bool = false,
  disabled? : () -> Bool = fn() { false },
) -> Unit {
  let able = fn() { !((self.off)() || disabled()) }
  v.focusable(By(able), keys=0) |> ignore
  v.owns(fn() {
    match self.draft.untracked() {
      Some(d) if d.key == key => self.cancel()
      _ => ()
    }
  })
  |> ignore
  v.on_key(fn(k) {
    if !v.focused() || k.mods != 0 || (self.off)() || disabled() {
      return false
    }
    match self.draft.untracked() {
      None =>
        if k.code == typeahead_key_space {
          let ks = (self.keys)()
          match ks.search(key) {
            Some(idx) => {
              self.pending.val = None
              self.draft.set(Some({ key, from_index: idx, to_index: idx, by_keyboard: true }))
              true
            }
            None => false
          }
        } else {
          false
        }
      Some(d) =>
        if !d.by_keyboard || d.key != key {
          false
        } else {
          let (prev_keys, next_keys) = axis_keys(self.axis, rtl)
          let n = (self.keys)().length()
          let max_idx = if n > 0 { n - 1 } else { 0 }
          if prev_keys.contains(k.code) {
            let next = if d.to_index > 0 { d.to_index - 1 } else { 0 }
            self.draft.set(Some({ ..d, to_index: next }))
            true
          } else if next_keys.contains(k.code) {
            let next = if d.to_index < max_idx { d.to_index + 1 } else { max_idx }
            self.draft.set(Some({ ..d, to_index: next }))
            true
          } else if k.code == group_key_home {
            self.draft.set(Some({ ..d, to_index: 0 }))
            true
          } else if k.code == group_key_end {
            self.draft.set(Some({ ..d, to_index: max_idx }))
            true
          } else if k.code == typeahead_key_space || k.code == combo_key_enter {
            self.commit()
            true
          } else if k.code == menu_key_escape {
            self.cancel()
            true
          } else {
            false
          }
        }
    }
  })
  |> ignore
}

///|
/// Pure array reorder helper: returns a new array with the element at `from` moved to index `to` (clamped to valid
/// bounds). Returns a shallow copy unchanged if `from` is out of range or `from == to`.
pub fn[K] reorder_apply(items : Array[K], from : Int, to : Int) -> Array[K] {
  let n = items.length()
  if n == 0 || from < 0 || from >= n {
    return items.copy()
  }
  let target = if to < 0 { 0 } else if to >= n { n - 1 } else { to }
  if from == target {
    return items.copy()
  }
  let out : Array[K] = []
  let moved = items[from]
  for i in 0..<n {
    if i != from {
      out.push(items[i])
    }
  }
  out.insert(target, moved)
  out
}

///|
/// Active cross-container transfer state: moving `key` from `(from_container, from_index)` to
/// `(to_container, to_index)`, and whether started via the keyboard.
#derive(Eq, Debug)
pub(all) struct TransferDraft[C, K] {
  key : K
  from_container : C
  from_index : Int
  to_container : C
  to_index : Int
  by_keyboard : Bool
}

///|
/// Cross-container transfer controller (e.g. kanban columns) supporting both within-container reordering and
/// across-container movement via programmatic API or keyboard-accessible bindings.
pub struct Transfer[C, K] {
  priv containers : () -> Array[C]
  priv items_of : (C) -> Array[K]
  priv on_transfer : (K, C, Int, C, Int) -> Unit
  priv off : () -> Bool
  priv draft : @signals.Signal[TransferDraft[C, K]?]
}

///|
/// Create a new `Transfer[C, K]` controller over containers returned by `containers`, each container's items returned by
/// `items_of`. Committing a move calls `on_transfer(key, from_container, from_index, to_container, to_index)`.
pub fn[C : Eq, K : Eq] Transfer::new(
  containers : () -> Array[C],
  items_of : (C) -> Array[K],
  on_transfer : (K, C, Int, C, Int) -> Unit,
  disabled? : () -> Bool = fn() { false },
) -> Transfer[C, K] {
  { containers, items_of, on_transfer, off: disabled, draft: @signals.signal(None) }
}

///|
/// The current active transfer draft, if any. Tracked when read inside a binding.
pub fn[C, K] Transfer::active(self : Transfer[C, K]) -> TransferDraft[C, K]? {
  self.draft.get()
}

///|
/// Whether `key` is currently being transferred. Tracked when read inside a binding.
pub fn[C, K : Eq] Transfer::is_transferring(self : Transfer[C, K], key : K) -> Bool {
  match self.draft.get() {
    Some(d) => d.key == key
    None => false
  }
}

///|
/// Clamp target insertion index within `container` relative to the draft's origin container.
fn[C : Eq, K] Transfer::clamp_index(self : Transfer[C, K], container : C, from_container : C, index : Int) -> Int {
  let n = (self.items_of)(container).length()
  let max_idx = if container == from_container {
    if n > 0 {
      n - 1
    } else {
      0
    }
  } else {
    n
  }
  if index < 0 {
    0
  } else if index > max_idx {
    max_idx
  } else {
    index
  }
}

///|
/// Begin transferring `key` from `container`.
pub fn[C, K : Eq] Transfer::start(self : Transfer[C, K], container : C, key : K) -> Unit {
  if (self.off)() {
    return
  }
  let items = (self.items_of)(container)
  guard items.search(key) is Some(idx) else { return }
  self.draft.set(
    Some({
      key,
      from_container: container,
      from_index: idx,
      to_container: container,
      to_index: idx,
      by_keyboard: false,
    }),
  )
}

///|
/// Move the active transfer draft to `(container, index)` (clamped to valid bounds for `container`).
pub fn[C : Eq, K] Transfer::move_to(self : Transfer[C, K], container : C, index : Int) -> Unit {
  if (self.off)() {
    self.cancel()
    return
  }
  match self.draft.untracked() {
    Some(d) => {
      let clamped = self.clamp_index(container, d.from_container, index)
      self.draft.set(Some({ ..d, to_container: container, to_index: clamped }))
    }
    None => ()
  }
}

///|
/// Step the active transfer draft's target index within its current target container by `delta`.
pub fn[C : Eq, K] Transfer::step_item(self : Transfer[C, K], delta : Int) -> Unit {
  match self.draft.untracked() {
    Some(d) => self.move_to(d.to_container, d.to_index + delta)
    None => ()
  }
}

///|
/// Step the active transfer draft's target container by `delta` along `containers()`, clamping `to_index` into the new
/// container's bounds.
pub fn[C : Eq, K] Transfer::step_container(self : Transfer[C, K], delta : Int) -> Unit {
  if (self.off)() {
    self.cancel()
    return
  }
  match self.draft.untracked() {
    Some(d) => {
      let cs = (self.containers)()
      let n = cs.length()
      if n == 0 {
        return
      }
      guard cs.search(d.to_container) is Some(ci) else { return }
      let raw = ci + delta
      let next_ci = if raw < 0 { 0 } else if raw >= n { n - 1 } else { raw }
      if next_ci != ci {
        let next_c = cs[next_ci]
        let clamped = self.clamp_index(next_c, d.from_container, d.to_index)
        self.draft.set(Some({ ..d, to_container: next_c, to_index: clamped }))
      }
    }
    None => ()
  }
}

///|
/// Commit the active transfer, calling `on_transfer(key, from_container, from_index, to_container, to_index)` when the
/// container or index changed, and exit the active state.
pub fn[C : Eq, K] Transfer::commit(self : Transfer[C, K]) -> Unit {
  match self.draft.untracked() {
    Some(d) => {
      self.draft.set(None)
      if !(self.off)() && (d.from_container != d.to_container || d.from_index != d.to_index) {
        (self.on_transfer)(d.key, d.from_container, d.from_index, d.to_container, d.to_index)
      }
    }
    None => ()
  }
}

///|
/// Cancel the active transfer without calling `on_transfer`.
pub fn[C, K] Transfer::cancel(self : Transfer[C, K]) -> Unit {
  self.draft.set(None)
}

///|
/// Bind keyboard-accessible cross-container transfer onto item node `v` for `(container, key)`:
/// - `Space` grabs the focused item (`by_keyboard = true`);
/// - `↑`/`↓` adjust position within the target container (`Home`/`End` jump to start/end);
/// - `←`/`→` (flipped when `rtl=true`) switch target container;
/// - `Space` or `Enter` commits (`on_transfer`) and exits grabbed state;
/// - `Escape` cancels without committing.
pub fn[C : Eq, K : Eq] Transfer::item(
  self : Transfer[C, K],
  v : @view.View,
  container : C,
  key : K,
  rtl? : Bool = false,
  disabled? : () -> Bool = fn() { false },
) -> Unit {
  let able = fn() { !((self.off)() || disabled()) }
  v.focusable(By(able), keys=0) |> ignore
  v.owns(fn() {
    match self.draft.untracked() {
      Some(d) if d.key == key && d.from_container == container => self.cancel()
      _ => ()
    }
  })
  |> ignore
  v.on_key(fn(k) {
    if !v.focused() || k.mods != 0 || (self.off)() || disabled() {
      return false
    }
    match self.draft.untracked() {
      None =>
        if k.code == typeahead_key_space {
          let items = (self.items_of)(container)
          match items.search(key) {
            Some(idx) => {
              self.draft.set(
                Some({
                  key,
                  from_container: container,
                  from_index: idx,
                  to_container: container,
                  to_index: idx,
                  by_keyboard: true,
                }),
              )
              true
            }
            None => false
          }
        } else {
          false
        }
      Some(d) =>
        if !d.by_keyboard || d.key != key || d.from_container != container {
          false
        } else if k.code == group_key_up {
          self.step_item(-1)
          true
        } else if k.code == group_key_down {
          self.step_item(1)
          true
        } else if k.code == group_key_left {
          self.step_container(if rtl { 1 } else { -1 })
          true
        } else if k.code == group_key_right {
          self.step_container(if rtl { -1 } else { 1 })
          true
        } else if k.code == group_key_home {
          self.move_to(d.to_container, 0)
          true
        } else if k.code == group_key_end {
          let n = (self.items_of)(d.to_container).length()
          self.move_to(d.to_container, n)
          true
        } else if k.code == typeahead_key_space || k.code == combo_key_enter {
          self.commit()
          true
        } else if k.code == menu_key_escape {
          self.cancel()
          true
        } else {
          false
        }
    }
  })
  |> ignore
}
