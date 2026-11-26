// Queue-free, single-slot, version-gated optimistic choice helper isolated by scope and core generation.
// Keeps the latest user intent visible immediately across rapid clicks while strictly guarding against
// stale topic snapshots, late RPC callbacks, scope switches, and in-place core restarts.

///|
fn opt_seq(v : Json?, key : String) -> Int64? {
  match field(v, key) {
    Some(Number(n, ..)) => Some(n.to_int64())
    _ => None
  }
}

///|
fn opt_batch(f : () -> Unit) -> Unit {
  @signals.start_batch()
  f()
  @signals.end_batch()
}

///|
priv struct OptimisticChoice[S, T] {
  core : Core
  scope : () -> S
  topic_name : String
  topic_params : (S) -> Map[String, Json]
  read_val : (Json?) -> T
  read_seq : (Json?) -> Int64?
  accepted_auth : @signals.Signal[T]
  opt : @signals.Optimistic[T]
  last_accepted_seq : Ref[Int64?]
  known_versioned : Ref[Bool]
  acked_need_seq : Ref[Int64?]
  active_remove : Ref[(() -> Unit)?]
  active_want : Ref[T?]
  unversioned_queue : Ref[Array[T]]
  restarting_gen : Ref[Bool]
  unversioned_acked : Ref[Bool]
  current_scope : Ref[S]
  scope_gen : Ref[Int]
  core_gen : Ref[Int]
  active_seq : Ref[Int]
  alive : Ref[Bool]
}

///|
fn[S : Eq, T : Eq] OptimisticChoice::new(
  host : @view.View,
  core : Core,
  scope : () -> S,
  topic_name : String,
  topic_params : (S) -> Map[String, Json],
  read_val : (Json?) -> T,
  read_seq : (Json?) -> Int64?,
) -> OptimisticChoice[S, T] {
  let init_scope = @signals.untracked(scope)
  let init_params = topic_params(init_scope)
  let init_read = @signals.untracked(fn() { (core.topic)(topic_name, init_params).get() })
  let (init_gen, init_fresh) = (core.generation)(topic_name, init_params)
  let init_val = read_val(init_read.value)
  let init_seq = if init_fresh { read_seq(init_read.value) } else { None }
  let accepted_auth = @signals.signal(init_val)
  let opt = @signals.optimistic(fn() { accepted_auth.get() })
  let state : OptimisticChoice[S, T] = {
    core,
    scope,
    topic_name,
    topic_params,
    read_val,
    read_seq,
    accepted_auth,
    opt,
    last_accepted_seq: Ref(init_seq),
    known_versioned: Ref(init_seq is Some(_)),
    acked_need_seq: Ref(None),
    active_remove: Ref(None),
    active_want: Ref(None),
    unversioned_queue: Ref([]),
    restarting_gen: Ref(false),
    unversioned_acked: Ref(false),
    current_scope: Ref(init_scope),
    scope_gen: Ref(0),
    core_gen: Ref(init_gen),
    active_seq: Ref(0),
    alive: Ref(true),
  }
  host.reacts(at_start=false, scope, fn(new_scope) { state.reset_scope(new_scope) })
  host.reacts(
    at_start=false,
    fn() {
      let sc = scope()
      (sc, (core.topic)(topic_name, topic_params(sc)).get())
    },
    fn(pair) {
      let (sc, rd) = pair
      let (gen, fresh) = (core.generation)(topic_name, topic_params(sc))
      state.on_topic(sc, read_val(rd.value), read_seq(rd.value), rd.value is Some(_), gen, fresh)
    },
  )
  host.owns(fn() {
    state.alive.val = false
    state.scope_gen.val += 1
    state.active_seq.val += 1
    state.restarting_gen.val = false
    state.clear_slot()
    state.clear_burst()
    state.acked_need_seq.val = None
  })
  |> ignore
  state
}

///|
fn[S, T] OptimisticChoice::clear_burst(self : OptimisticChoice[S, T]) -> Unit {
  self.unversioned_queue.val = []
  self.unversioned_acked.val = false
}

///|
fn[S, T] OptimisticChoice::clear_slot(self : OptimisticChoice[S, T]) -> Unit {
  self.active_want.val = None
  match self.active_remove.val {
    Some(rem) => {
      self.active_remove.val = None
      rem()
    }
    None => ()
  }
}

///|
fn[S, T] OptimisticChoice::sync_core_gen(self : OptimisticChoice[S, T], gen : Int) -> Unit {
  if gen != self.core_gen.val {
    self.core_gen.val = gen
    self.restarting_gen.val = true
    self.scope_gen.val += 1
    self.active_seq.val += 1
    self.clear_slot()
    self.clear_burst()
    self.acked_need_seq.val = None
    self.last_accepted_seq.val = None
    // Keep accepted_auth (no blank flash) and known_versioned across the restart transition window.
  }
}

///|
fn[S : Eq, T] OptimisticChoice::reset_scope(self : OptimisticChoice[S, T], new_scope : S) -> Unit {
  if !self.alive.val || new_scope == self.current_scope.val {
    return
  }
  let params = (self.topic_params)(new_scope)
  let rd = @signals.untracked(fn() { (self.core.topic)(self.topic_name, params).get() })
  let (gen, fresh) = (self.core.generation)(self.topic_name, params)
  let next_val = (self.read_val)(rd.value)
  let next_seq = if fresh { (self.read_seq)(rd.value) } else { None }
  opt_batch(fn() {
    self.current_scope.val = new_scope
    self.restarting_gen.val = false
    self.scope_gen.val += 1
    self.active_seq.val += 1
    self.clear_slot()
    self.clear_burst()
    self.acked_need_seq.val = None
    self.last_accepted_seq.val = next_seq
    self.known_versioned.val = next_seq is Some(_)
    self.core_gen.val = gen
    self.accepted_auth.set(next_val)
  })
}

///|
fn[S, T] OptimisticChoice::try_handoff(self : OptimisticChoice[S, T]) -> Unit {
  match (self.acked_need_seq.val, self.last_accepted_seq.val) {
    (Some(need), Some(cur)) if cur >= need => {
      self.clear_slot()
      self.clear_burst()
      self.acked_need_seq.val = None
    }
    _ => ()
  }
}

///|
fn[S : Eq, T : Eq] OptimisticChoice::on_topic(
  self : OptimisticChoice[S, T],
  event_scope : S,
  val : T,
  seq : Int64?,
  val_present : Bool,
  gen : Int,
  fresh : Bool,
) -> Unit {
  if !self.alive.val || event_scope != self.current_scope.val {
    return
  }
  self.sync_core_gen(gen)
  if !fresh && val_present {
    return
  }
  self.restarting_gen.val = false
  match seq {
    Some(s) => {
      self.known_versioned.val = true
      self.clear_burst()
      match self.last_accepted_seq.val {
        Some(prev) if s < prev => return
        _ => ()
      }
      self.last_accepted_seq.val = Some(s)
      opt_batch(fn() {
        self.accepted_auth.set(val)
        self.try_handoff()
      })
    }
    None => {
      self.known_versioned.val = false
      self.last_accepted_seq.val = None
      if self.active_remove.val is Some(_) {
        if val == self.accepted_auth.untracked() {
          return
        }
        if self.unversioned_queue.val.contains(val) {
          if self.unversioned_acked.val && self.active_want.val == Some(val) {
            opt_batch(fn() {
              self.accepted_auth.set(val)
              self.clear_slot()
              self.clear_burst()
            })
          } else {
            self.accepted_auth.set(val)
          }
          return
        }
      }
      opt_batch(fn() {
        self.accepted_auth.set(val)
        self.clear_slot()
        self.clear_burst()
        self.acked_need_seq.val = None
      })
    }
  }
}

///|
fn[S : Eq, T : Eq] OptimisticChoice::submit(
  self : OptimisticChoice[S, T],
  want : T,
  send : (S, (Bool, Int64?) -> Unit) -> Unit,
) -> Unit {
  if !self.alive.val {
    return
  }
  let live_scope = @signals.untracked(self.scope)
  if live_scope != self.current_scope.val {
    self.reset_scope(live_scope)
  }
  let (gen, _) = (self.core.generation)(self.topic_name, (self.topic_params)(live_scope))
  self.sync_core_gen(gen)
  if want == self.opt.untracked() {
    return
  }
  self.unversioned_acked.val = false
  self.active_seq.val += 1
  let g = self.scope_gen.val
  let cg = self.core_gen.val
  let sq = self.active_seq.val
  if !self.known_versioned.val || self.restarting_gen.val {
    if !self.unversioned_queue.val.contains(want) {
      self.unversioned_queue.val.push(want)
    }
  }
  // Always hold the single optimistic slot while RPC is in flight (including legacy unversioned fallback,
  // where deduplicated unversioned_queue holds burst values for eventual consistency until a confirming
  // or unexpected external topic arrives; shipping core-ts always supplies monotonic progressSeq / rev).
  opt_batch(fn() {
    self.clear_slot()
    self.active_want.val = Some(want)
    self.active_remove.val = Some(self.opt.set_value(want))
    self.acked_need_seq.val = None
  })
  send(live_scope, fn(ok, ack_seq) { self.on_done(g, cg, sq, ok, ack_seq) })
}

///|
fn[S, T : Eq] OptimisticChoice::on_done(
  self : OptimisticChoice[S, T],
  g : Int,
  cg : Int,
  sq : Int,
  ok : Bool,
  ack_seq : Int64?,
) -> Unit {
  if !self.alive.val || g != self.scope_gen.val || cg != self.core_gen.val {
    return
  }
  if ok && ack_seq is Some(_) {
    self.known_versioned.val = true
    self.restarting_gen.val = false
    self.clear_burst()
  }
  if sq != self.active_seq.val {
    return
  }
  if !ok {
    self.clear_slot()
    self.clear_burst()
    self.acked_need_seq.val = None
    return
  }
  match ack_seq {
    Some(need) => {
      self.known_versioned.val = true
      self.restarting_gen.val = false
      self.clear_burst()
      self.acked_need_seq.val = Some(need)
      self.try_handoff()
    }
    None => {
      self.known_versioned.val = false
      self.restarting_gen.val = false
      self.acked_need_seq.val = None
      if self.active_remove.val is None {
        self.clear_burst()
        return
      }
      let mut has_other = false
      for x in self.unversioned_queue.val {
        if self.active_want.val != Some(x) {
          has_other = true
          break
        }
      }
      if !has_other && self.active_want.val == Some(self.accepted_auth.untracked()) {
        opt_batch(fn() {
          self.clear_slot()
          self.clear_burst()
        })
        return
      }
      // Pure event-driven legacy fallback (no time windows per AGENTS.md, never forge accepted_auth):
      // hold the optimistic slot until the confirming topic or an external topic arrives.
      // Shipping core-ts always supplies local monotonic progressSeq / rev for exact causal ordering.
      self.unversioned_acked.val = true
    }
  }
}

///|
fn[S, T] OptimisticChoice::get(self : OptimisticChoice[S, T]) -> T {
  self.opt.get()
}

///|
#warnings("-unused_value")
fn[S, T] OptimisticChoice::is_pending(self : OptimisticChoice[S, T]) -> Bool {
  self.opt.is_pending()
}
