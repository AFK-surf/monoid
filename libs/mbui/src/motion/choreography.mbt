// A multi-track scene transition choreography built on closed-form Ways: every track shares one cause moment, runs
// independently with its own forward/backward Spec (delay, duration, easing or spring), reverses mid-flight from exact
// position and velocity with zero discontinuity, and arms cleanup on any participating tree node without leaking.

///|
/// One named track of a Choreography: its forward Spec (0 -> 1) and backward Spec (current -> 0).
pub(all) struct TrackSpec {
  name : String
  forward : Spec
  backward : Spec
}

///|
/// Multi-track scene transition coordinator driven by closed-form Ways.
pub struct Choreography {
  priv specs : Array[TrackSpec]
  priv ways : Array[Way]
  priv ended : @signals.Signal[Int]
  priv due : Array[(@view.NodeId, () -> Unit)]
}

///|
/// Create a choreography at rest (all tracks at 0.0).
pub fn Choreography::new(tracks : Array[TrackSpec]) -> Choreography {
  let ways = tracks.map(fn(_) { Way::new(0.0) })
  { specs: tracks.copy(), ways, ended: @signals.signal(0), due: [] }
}

///|
/// Find track index by name; -1 if not found.
fn Choreography::index_of(self : Choreography, name : String) -> Int {
  for i, s in self.specs {
    if s.name == name {
      return i
    }
  }
  -1
}

///|
/// Start all tracks forward (0.0 -> 1.0) from cause moment `at`. Under reduced motion, snaps immediately to 1.0.
#callsite(autofill(loc))
pub fn Choreography::start(self : Choreography, at : Double, loc~ : SourceLoc) -> Unit {
  self.stop()
  if @ui.reduced_motion() {
    for w in self.ways {
      w.put(1.0, loc~)
    }
    return
  }
  for i, w in self.ways {
    w.put(0.0, loc~)
    w.go(1.0, self.specs[i].forward, at~, loc~)
  }
}

///|
/// Reverse all tracks toward 0.0 from exact position and velocity at moment `at`. Under reduced motion, snaps to 0.0.
#callsite(autofill(loc))
pub fn Choreography::reverse(self : Choreography, at : Double, loc~ : SourceLoc) -> Unit {
  self.stop()
  if @ui.reduced_motion() {
    for w in self.ways {
      w.put(0.0, loc~)
    }
    return
  }
  for i, w in self.ways {
    w.go(0.0, self.specs[i].backward, at~, loc~)
  }
}

///|
/// Snap all tracks silently to `v` (typically 0.0 or 1.0).
#callsite(autofill(loc))
pub fn Choreography::put(self : Choreography, v : Double, loc~ : SourceLoc) -> Unit {
  self.stop()
  for w in self.ways {
    w.put(v, loc~)
  }
}

///|
/// Arm the choreography's latest end moment on node `n`, tied to `n`'s lifetime via `owns_while`. Calling `arm` again
/// on the same node replaces its previous handle without leaking; arming multiple participating nodes is supported.
pub fn Choreography::arm(self : Choreography, n : @view.View) -> Unit {
  let id = n.id()
  // Replace any prior arm on this same node without disturbing other armed nodes.
  for i = self.due.length() - 1; i >= 0; i = i - 1 {
    if self.due[i].0 == id {
      let (_, cancel) = self.due.remove(i)
      cancel()
    }
  }
  let end = self.ends_at()
  guard end >= 0.0 && n.alive() else { return }
  let remove_entry = fn() {
    for i = self.due.length() - 1; i >= 0; i = i - 1 {
      if self.due[i].0 == id {
        self.due.remove(i) |> ignore
      }
    }
  }
  let unkeep : Ref[(() -> Unit)?] = Ref(None)
  let drop_unkeep = fn() {
    match unkeep.val {
      Some(f) => {
        unkeep.val = None
        f()
      }
      None => ()
    }
  }
  let stop_moment = n.at_moment(end, fn() {
    drop_unkeep()
    remove_entry()
    self.ended.set(self.ended.untracked() + 1)
  })
  unkeep.val = Some(
    n.owns_while(fn() {
      unkeep.val = None
      stop_moment()
      remove_entry()
    }),
  )
  self.due.push(
    (
      id,
      fn() {
        drop_unkeep()
        stop_moment()
      },
    ),
  )
}

///|
/// Reactive progress (0.0 .. 1.0) of track `name` as node `n` draws it; 0.0 if track not found.
pub fn Choreography::progress(self : Choreography, n : @view.View, name : String) -> Double {
  self.ended.get() |> ignore
  let i = self.index_of(name)
  if i < 0 {
    0.0
  } else {
    self.ways[i].shown_on(n)
  }
}

///|
/// Pure evaluation of track `name` at moment `t`; 0.0 if track not found.
pub fn Choreography::value_at(self : Choreography, name : String, t : Double) -> Double {
  let i = self.index_of(name)
  if i < 0 {
    0.0
  } else {
    self.ways[i].value_at(t)
  }
}

///|
/// Whether any track is still moving at `n`'s logic moment (reactive).
pub fn Choreography::active(self : Choreography, n : @view.View) -> Bool {
  self.ended.get() |> ignore
  for w in self.ways {
    w.said()
  }
  n.goes_now(fn(at) { self.ways.iter().any(fn(w) { w.goes_at(at) }) })
}

///|
/// Latest end timestamp across all active tracks, or -1.0 when all tracks are at rest.
pub fn Choreography::ends_at(self : Choreography) -> Double {
  let mut max_end = -1.0
  for w in self.ways {
    let e = w.ends_at()
    if e >= 0.0 && e > max_end {
      max_end = e
    }
  }
  max_end
}

///|
/// Total span (ms) from earliest track start to latest track end when running, or the nominal forward span from
/// declared TrackSpecs when at rest (useful for aligning `View::show(leave=...)`).
pub fn Choreography::duration(self : Choreography) -> Double {
  let mut min_start = @double.infinity
  let mut max_end = -1.0
  for w in self.ways {
    let s = w.starts_at()
    let e = w.ends_at()
    if s >= 0.0 && e >= 0.0 {
      if s < min_start {
        min_start = s
      }
      if e > max_end {
        max_end = e
      }
    }
  }
  if max_end >= 0.0 && min_start < @double.infinity {
    max_end - min_start
  } else {
    let mut nominal = 0.0
    for spec in self.specs {
      let d = spec.forward.duration(0.0, 1.0, 0.0)
      if d > nominal {
        nominal = d
      }
    }
    nominal
  }
}

///|
/// Declared forward delay (ms) of track `name`; 0.0 if not found.
pub fn Choreography::track_delay(self : Choreography, name : String) -> Double {
  let i = self.index_of(name)
  if i < 0 {
    0.0
  } else {
    self.specs[i].forward.delay()
  }
}

///|
/// Cancel all pending end timers without changing track values.
pub fn Choreography::stop(self : Choreography) -> Unit {
  if self.due.is_empty() {
    return
  }
  let pending = self.due.copy()
  self.due.clear()
  for entry in pending {
    (entry.1)()
  }
}
