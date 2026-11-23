// Generic, pure-data list presentation scheduler: coordinates barrier holding, co-moving activity items,
// deferred trailer items, lingering anchor placeholders, predecessor-change rekeying, and bridged pair detection
// on a deterministic logical clock (`now : Double` in ms) without depending on views, signals, or timers.

///|
/// Logical lane of a list item for staging rules.
#derive(Eq, Debug)
pub(all) enum StageLane {
  Structural
  Content
  Activity
  Trailer
}

///|
/// How a newly arrived item behaves while a barrier or hold is active.
#derive(Eq, Debug)
pub(all) enum StageDuringBarrier {
  Keep
  DeferUntilBarriers
  CoMoveWithBarrier
}

///|
/// Declarative staging policy of a list item.
#derive(Eq)
pub(all) struct StagePolicy {
  lane : StageLane
  during_barrier : StageDuringBarrier
  rekey_on_prev_change : Bool
  hold_as_anchor : Bool
  live_removable : Bool
}

///|
/// Custom hold plan for an item with an explicit release moment and optional lingering key.
#derive(Eq)
pub(all) struct StageHoldPlan {
  release_at : Double
  has_custom_plan : Bool
  linger_key : String?
}

///|
/// Per-item ingest descriptor returned by caller inspection for tail items.
pub(all) struct StageIngestItem {
  policy : StagePolicy
  starts_barrier_until : Double?
  custom_hold : StageHoldPlan?
}

///|
/// Result of one `ListStage::ingest` step.
pub(all) struct StageStepResult {
  visible : Array[String]
  newly_held : Array[String]
  dropped_held : Array[String]
  dropped_lingers : Array[String]
  next_due : Double?
}

///|
/// Result of one `ListStage::tick` step.
pub(all) struct StageReleaseResult {
  visible : Array[String]
  released : Array[String]
  released_lingers : Array[String]
  rescheduled : Array[(String, Double)]
  next_due : Double?
}

///|
/// Result of one `ListStage::flush` step.
pub(all) struct StageFlushResult {
  visible : Array[String]
  flushed : Array[String]
  flushed_lingers : Array[String]
}

///|
/// Stateful pure-data list presentation stage.
pub struct ListStage {
  priv tail_window : Int
  priv is_rekey : (String) -> Bool
  priv mut raw_was : Array[String]
  priv mut visible_cache : Array[String]
  priv mut barrier_until : Double
  priv held : Map[String, StageHoldPlan]
  priv lingering : Map[String, String?]
  priv flushed : Map[String, Bool]
  priv shows_at : Map[String, Double]
  priv rekey_tracked : Map[String, (Int, String?)]
  priv alias_to_raw : Map[String, String]
  priv bridged : Map[String, Bool]
}

///|
/// Create an empty `ListStage` with a bounded tail inspection window and a pure key predicate `is_rekey`
/// used on initial/non-staged ingests without invoking `inspect`.
pub fn ListStage::new(tail_window? : Int = 64, is_rekey? : (String) -> Bool = fn(_) { false }) -> ListStage {
  let win = if tail_window > 0 { tail_window } else { 64 }
  {
    tail_window: win,
    is_rekey,
    raw_was: [],
    visible_cache: [],
    barrier_until: -1.0,
    held: Map([]),
    lingering: Map([]),
    flushed: Map([]),
    shows_at: Map([]),
    rekey_tracked: Map([]),
    alias_to_raw: Map([]),
    bridged: Map([]),
  }
}

///|
/// Extend the active barrier deadline to at least `until`.
pub fn ListStage::extend_barrier(self : ListStage, until : Double) -> Unit {
  if until > self.barrier_until {
    self.barrier_until = until
  }
}

///|
/// Current barrier deadline (-1.0 when none has been set).
pub fn ListStage::barrier_until(self : ListStage) -> Double {
  self.barrier_until
}

///|
fn stage_max_int(a : Int, b : Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn stage_prev_non_held(ks : Array[String], k : String, held : Map[String, StageHoldPlan]) -> String? {
  let mut i = ks.length() - 1
  while i >= 0 && ks[i] != k {
    i = i - 1
  }
  i = i - 1
  while i >= 0 {
    if !held.contains(ks[i]) {
      return Some(ks[i])
    }
    i = i - 1
  }
  None
}

///|
fn stage_has_linger_owner(held : Map[String, StageHoldPlan], lk : String) -> Bool {
  for _, p in held {
    if p.linger_key == Some(lk) {
      return true
    }
  }
  false
}

///|
fn ListStage::project_visible(self : ListStage, raw_keys : Array[String]) -> Array[String] {
  let base = if self.held.is_empty() {
    raw_keys
  } else {
    let out : Array[String] = []
    for k in raw_keys {
      if !self.held.contains(k) {
        out.push(k)
      }
    }
    for lk, prev_opt in self.lingering {
      if out.contains(lk) {
        continue
      }
      let at = match prev_opt {
        Some(b) =>
          match out.search(b) {
            Some(i) => i + 1
            None => out.length()
          }
        None => out.length()
      }
      out.insert(at, lk)
    }
    out
  }
  if self.rekey_tracked.is_empty() {
    self.visible_cache = base
    return base
  }
  let hits : Array[(Int, String)] = []
  let tracked_keys = self.rekey_tracked.keys().collect()
  for rk in tracked_keys {
    let mut found = -1
    let mut i = base.length() - 1
    while i >= 0 {
      if base[i] == rk {
        found = i
        break
      }
      i = i - 1
    }
    if found >= 0 {
      hits.push((found, rk))
    } else {
      let (gen, _) = self.rekey_tracked[rk]
      self.rekey_tracked[rk] = (gen, None)
    }
  }
  if hits.is_empty() {
    self.visible_cache = base
    return base
  }
  hits.sort_by(fn(a, b) { a.0.compare(b.0) })
  let mut projected = base
  let mut copied = !physical_equal(base, raw_keys)
  for hit in hits {
    let (idx, rk) = hit
    let (gen0, last_prev) = self.rekey_tracked[rk]
    let prev_k = if idx > 0 { Some(projected[idx - 1]) } else { None }
    let gen = match last_prev {
      Some(was_prev) if prev_k != Some(was_prev) => gen0 + 1
      _ => gen0
    }
    self.rekey_tracked[rk] = (gen, prev_k)
    if gen > 0 {
      let ak = rk + ":" + gen.to_string()
      self.alias_to_raw[ak] = rk
      if !copied {
        projected = base.copy()
        copied = true
      }
      projected[idx] = ak
    }
  }
  self.visible_cache = projected
  projected
}

///|
/// Ingest a new raw key sequence at logical time `now`. Only inspects a bounded tail window (O(tail)).
/// Preserves `physical_equal(visible, raw_keys)` when nothing is held and no active rekey alias applies.
pub fn ListStage::ingest(
  self : ListStage,
  raw_keys : Array[String],
  now : Double,
  can_stage : Bool,
  inspect : (String) -> StageIngestItem,
) -> StageStepResult {
  let newly_held : Array[String] = []
  let dropped_held : Array[String] = []
  let dropped_lingers : Array[String] = []
  if self.raw_was.is_empty() || !can_stage {
    let start = stage_max_int(raw_keys.length() - self.tail_window, 0)
    for j in start..<raw_keys.length() {
      let k = raw_keys[j]
      if (self.is_rekey)(k) && !self.rekey_tracked.contains(k) {
        self.rekey_tracked[k] = (0, None)
      }
    }
    self.raw_was = raw_keys
    let visible = self.project_visible(raw_keys)
    return { visible, newly_held, dropped_held, dropped_lingers, next_due: self.next_due_at() }
  }
  let was = self.raw_was
  if !self.held.is_empty() {
    let present : Map[String, Bool] = Map([])
    for k in raw_keys {
      present[k] = true
    }
    let gone = self.held.keys().filter(fn(k) { !present.contains(k) }).collect()
    for k in gone {
      let plan_opt = self.held.get(k)
      self.held.remove(k)
      dropped_held.push(k)
      match plan_opt {
        Some({ linger_key: Some(lk), .. }) =>
          if !stage_has_linger_owner(self.held, lk) && self.lingering.contains(lk) {
            self.lingering.remove(lk)
            dropped_lingers.push(lk)
          }
        _ => ()
      }
    }
  }
  let seen : Map[String, Bool] = Map([])
  let seen_start = stage_max_int(was.length() - 2 * self.tail_window, 0)
  for i in seen_start..<was.length() {
    seen[was[i]] = true
  }
  let barrier_was = self.barrier_until
  let tail_start = stage_max_int(raw_keys.length() - self.tail_window, 0)
  for j in tail_start..<raw_keys.length() {
    let k = raw_keys[j]
    guard !seen.contains(k) && !self.held.contains(k) else { continue }
    let item = inspect(k)
    if item.policy.rekey_on_prev_change && !self.rekey_tracked.contains(k) {
      self.rekey_tracked[k] = (0, None)
    }
    match item.starts_barrier_until {
      Some(end) => if end > self.barrier_until { self.barrier_until = end }
      None => ()
    }
    match item.custom_hold {
      Some(plan) =>
        if plan.has_custom_plan || plan.release_at > now {
          self.flushed.remove(k)
          self.held[k] = plan
          newly_held.push(k)
          match plan.linger_key {
            Some(lk) => {
              let base_ks = if was.contains(lk) { was } else { raw_keys }
              self.lingering[lk] = stage_prev_non_held(base_ks, lk, self.held)
            }
            None => ()
          }
        }
      None =>
        match item.policy.during_barrier {
          CoMoveWithBarrier =>
            if self.barrier_until > now {
              if barrier_was <= now {
                self.shows_at[k] = self.barrier_until
              } else {
                self.shows_at.remove(k)
                self.flushed.remove(k)
                self.held[k] = { release_at: self.barrier_until, has_custom_plan: false, linger_key: None }
                newly_held.push(k)
              }
            }
          DeferUntilBarriers => {
            let mut until = self.barrier_until
            for _, p in self.held {
              if p.release_at > until {
                until = p.release_at
              }
            }
            if until > now {
              self.flushed.remove(k)
              self.held[k] = { release_at: until, has_custom_plan: false, linger_key: None }
              newly_held.push(k)
            }
          }
          Keep => ()
        }
    }
  }
  self.raw_was = raw_keys
  let visible = self.project_visible(raw_keys)
  { visible, newly_held, dropped_held, dropped_lingers, next_due: self.next_due_at() }
}

///|
/// Advance the stage to logical time `now`, releasing due held items or rescheduling them if an active barrier
/// extends past `now`.
pub fn ListStage::tick(self : ListStage, now : Double) -> StageReleaseResult {
  let due : Array[String] = []
  for k, p in self.held {
    if p.release_at <= now {
      due.push(k)
    }
  }
  if due.is_empty() {
    return {
      visible: self.visible_cache,
      released: [],
      released_lingers: [],
      rescheduled: [],
      next_due: self.next_due_at(),
    }
  }
  if self.barrier_until > now {
    let rescheduled : Array[(String, Double)] = []
    for k in due {
      let p = self.held[k]
      self.held[k] = { ..p, release_at: self.barrier_until }
      rescheduled.push((k, self.barrier_until))
    }
    return {
      visible: self.visible_cache,
      released: [],
      released_lingers: [],
      rescheduled,
      next_due: self.next_due_at(),
    }
  }
  let released : Array[String] = []
  let cand_lingers : Array[String] = []
  for k in due {
    let p = self.held[k]
    self.held.remove(k)
    released.push(k)
    match p.linger_key {
      Some(lk) => if !cand_lingers.contains(lk) { cand_lingers.push(lk) }
      None => ()
    }
  }
  let released_lingers : Array[String] = []
  for lk in cand_lingers {
    if !stage_has_linger_owner(self.held, lk) {
      self.lingering.remove(lk)
      released_lingers.push(lk)
    }
  }
  let visible = self.project_visible(self.raw_was)
  { visible, released, released_lingers, rescheduled: [], next_due: self.next_due_at() }
}

///|
/// Immediately release all held items and lingering anchors, marking flushed keys.
pub fn ListStage::flush(self : ListStage) -> StageFlushResult {
  let flushed = self.held.keys().collect()
  let flushed_lingers = self.lingering.keys().collect()
  for k in flushed {
    self.flushed[k] = true
  }
  self.held.clear()
  self.lingering.clear()
  self.bridged.clear()
  let visible = self.project_visible(self.raw_was)
  { visible, flushed, flushed_lingers }
}

///|
/// Recompute adjacent pairs in `visible` that are separated in `raw_was` exclusively by held items and satisfy `is_pair`.
pub fn ListStage::recompute_bridged(self : ListStage, is_pair : (String, String) -> Bool) -> Unit {
  self.bridged.clear()
  guard !self.held.is_empty() && self.visible_cache.length() >= 2 else { return }
  let pos : Map[String, Int] = Map([])
  for i, k in self.raw_was {
    pos[k] = i
  }
  for i in 0..<(self.visible_cache.length() - 1) {
    let a = self.visible_cache[i]
    let b = self.visible_cache[i + 1]
    let ra = self.unalias(a)
    let rb = self.unalias(b)
    guard pos.get(ra) is Some(ia) && pos.get(rb) is Some(ib) && ib > ia + 1 else { continue }
    let mut all_held = true
    for j in (ia + 1)..<ib {
      if !self.held.contains(self.raw_was[j]) {
        all_held = false
        break
      }
    }
    if all_held && is_pair(ra, rb) {
      self.bridged[b] = true
    }
  }
}

///|
/// Whether visible key `k` is currently bridged across held items to its predecessor.
pub fn ListStage::is_bridged(self : ListStage, k : String) -> Bool {
  self.bridged.contains(k)
}

///|
/// Earliest `release_at` among currently held items, or `None` when none are held.
pub fn ListStage::next_due_at(self : ListStage) -> Double? {
  let mut best : Double? = None
  for _, p in self.held {
    match best {
      Some(b) => if p.release_at < b { best = Some(p.release_at) }
      None => best = Some(p.release_at)
    }
  }
  best
}

///|
/// Resolve a possibly rekeyed alias back to its underlying raw key.
pub fn ListStage::unalias(self : ListStage, k : String) -> String {
  self.alias_to_raw.get(k).unwrap_or(k)
}

///|
/// Whether raw key `k` is currently held.
pub fn ListStage::is_held(self : ListStage, k : String) -> Bool {
  self.held.contains(k)
}

///|
/// Whether key `k` is currently kept as a lingering placeholder.
pub fn ListStage::is_lingering(self : ListStage, k : String) -> Bool {
  self.lingering.contains(k)
}

///|
/// Whether raw key `k` was flushed by `flush`.
pub fn ListStage::is_flushed(self : ListStage, k : String) -> Bool {
  self.flushed.contains(k)
}

///|
/// Reveal timestamp recorded for a `CoMoveWithBarrier` item (-1.0 when none).
pub fn ListStage::shows_at(self : ListStage, k : String) -> Double {
  self.shows_at.get(k).unwrap_or(-1.0)
}

///|
/// Clear any recorded reveal timestamp for key `k`.
pub fn ListStage::clear_shows_at(self : ListStage, k : String) -> Unit {
  self.shows_at.remove(k)
}

///|
/// Latest projected visible key sequence.
pub fn ListStage::visible_keys(self : ListStage) -> Array[String] {
  self.visible_cache
}

///|
/// Whether at least one item is currently held.
pub fn ListStage::has_held(self : ListStage) -> Bool {
  !self.held.is_empty()
}

///|
/// Active hold plan for raw key `k`, if held.
pub fn ListStage::held_plan(self : ListStage, k : String) -> StageHoldPlan? {
  self.held.get(k)
}

///|
/// Explicit causal origin of a list key sequence update.
#derive(Eq, Debug)
pub(all) enum StageOrigin {
  Initial
  Reopen
  PageOlder
  PageNewer
  CatchUp
  LocalSend
  LivePush
  UserAct
}

///|
/// Whether an update from this causal origin should animate list transitions.
pub fn StageOrigin::animates(self : StageOrigin) -> Bool {
  match self {
    Initial | Reopen | PageOlder | PageNewer | CatchUp => false
    LocalSend | LivePush | UserAct => true
  }
}

///|
/// Classification of a newly arrived tail item for causal origin detection.
#derive(Eq, Debug)
pub(all) enum StageArrivalKind {
  ArrivalStructural
  ArrivalLocalSend
  ArrivalLive
  ArrivalCatchUp
  ArrivalQuietActivity
}

///|
/// Pure-data causal origin tracker for list key updates without item-count cliff thresholds.
pub struct StageOriginTracker {
  priv is_anchor : (String) -> Bool
  priv mut judged : Array[String]?
  priv mut last_origin : StageOrigin
  priv mut had : Array[String]
  priv mut settled : Bool
}

///|
/// Create a new `StageOriginTracker` with an anchor predicate `is_anchor`.
pub fn StageOriginTracker::new(is_anchor? : (String) -> Bool = fn(_) { true }) -> StageOriginTracker {
  { is_anchor, judged: None, last_origin: Initial, had: [], settled: false }
}

///|
/// Classify the causal origin of `keys` against the previously observed key sequence.
/// Idempotent on identical array references (`physical_equal`); only calls `classify_added` for newly arrived tail
/// keys when `was_settled && !reopening && at_tail && first_kept >= 0`.
pub fn StageOriginTracker::classify(
  self : StageOriginTracker,
  keys : Array[String],
  settled : Bool,
  reopening : Bool,
  at_tail : Bool,
  classify_added : (String) -> StageArrivalKind,
  is_live_removable : (String) -> Bool,
) -> StageOrigin {
  match self.judged {
    Some(j) if physical_equal(j, keys) => return self.last_origin
    _ => ()
  }
  self.judged = Some(keys)
  let was_settled = self.settled
  self.settled = settled
  let now : Array[String] = []
  let seen : Map[String, Bool] = Map([])
  for k in keys {
    if !seen.contains(k) {
      seen[k] = true
      now.push(k)
    }
  }
  let was = self.had
  self.had = now
  let in_was : Map[String, Bool] = Map([])
  for k in was {
    in_was[k] = true
  }
  let mut first_kept = -1
  for i, k in was {
    if seen.contains(k) && (self.is_anchor)(k) {
      first_kept = i
      break
    }
  }
  let came : Array[String] = []
  let mut prepended = false
  if first_kept >= 0 {
    match now.search(was[first_kept]) {
      Some(from) => {
        for i in 0..<from {
          if !in_was.contains(now[i]) {
            prepended = true
            break
          }
        }
        for i in (from + 1)..<now.length() {
          if !in_was.contains(now[i]) {
            came.push(now[i])
          }
        }
      }
      None => ()
    }
  }
  let origin : StageOrigin = if !was_settled {
    Initial
  } else if reopening {
    Reopen
  } else if !at_tail {
    PageNewer
  } else if first_kept < 0 {
    CatchUp
  } else {
    let mut has_catch_up = false
    let mut has_local_send = false
    let mut has_live = false
    for k in came {
      match classify_added(k) {
        ArrivalCatchUp => {
          has_catch_up = true
          break
        }
        ArrivalLocalSend => has_local_send = true
        ArrivalLive => has_live = true
        ArrivalStructural | ArrivalQuietActivity => ()
      }
    }
    if has_catch_up {
      CatchUp
    } else if has_local_send {
      LocalSend
    } else if has_live {
      LivePush
    } else {
      let mut has_live_removed = false
      for i in (first_kept + 1)..<was.length() {
        let k = was[i]
        if !seen.contains(k) && is_live_removable(k) {
          has_live_removed = true
          break
        }
      }
      if has_live_removed {
        LivePush
      } else if prepended {
        PageOlder
      } else {
        CatchUp
      }
    }
  }
  self.last_origin = origin
  origin
}
