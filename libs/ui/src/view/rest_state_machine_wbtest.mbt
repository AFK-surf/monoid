///|
/// State-machine tests for PR-B1:
/// - `View::on_rest` / `View::when_active` (`while_covered`, per-Tree index, single disposal path)
/// - `covered -> deep -> wake` preserving `@signals.rest` wake closures
/// - Nested parking pool propagation (inner `EachKept` `keeps_holds=true` inside outer `park`)
/// - Strict sleep (pre-order bindings, post-order hooks, LIFO per node) & wake (pre-order hooks FIFO -> bindings)
/// - Registration while asleep, `View::rests()`, detached live nodes, synchronous re-entrancy
/// - `View::at_moment(while_active=true)`, `View::while_active_every`, `Tree::subtree_timeline_count`
/// - Extended `View::pick` / `View::switch_by` (`keeps_max`, `pin`, `keep_if`, `on_take`, `retire_parked`)

///|
test "rest state machine: mixed while_covered hooks, covered -> deep -> wake preserves signal wakes with 0 sleep re-reads" {
  let keys = @signals.signal(["a"], same=fn(a, b) { a == b })
  let kept = @signals.signal(["a"], same=fn(a, b) { a == b })
  let holding = @signals.signal(true, same=fn(a, b) { a == b })
  let held = @signals.signal(1, same=fn(a, b) { a == b })
  let unheld = Ref(0)
  held.on_unwatched(fn() { unheld.val += 1 })
  let log : Array[String] = []
  let reads = Ref(0)
  let t = Tree::new(fn(root) {
    root.each(
      at_once=true,
      fn() { keys.get() },
      fn(k) { k },
      keeps=fn() { kept.get() },
      keeps_holds=fn(_) { holding.untracked() },
      fn(v, _) {
        v
        .when_active(while_covered=false, fn() {
          log.push("deep:enter")
          fn() { log.push("deep:leave") }
        })
        .when_active(while_covered=true, fn() {
          log.push("cov:enter")
          fn() { log.push("cov:leave") }
        })
        .height(Is(Some(20.0)))
        .words(By(fn() {
          reads.val += 1
          "v=\{held.get()}"
        }))
        |> ignore
      },
    )
  })
  t.frame(300.0, 200.0, now=0.0) |> ignore
  assert_eq(log, ["deep:enter", "cov:enter"])
  assert_true(held.watched())
  let reads_before = reads.val

  // 1. Park into `covered` (`keeps_holds = true`): only `while_covered=true` rests; holds stay watched.
  t.event(16.0, fn() { keys.set([]) })
  t.frame(300.0, 200.0, now=16.0) |> ignore
  assert_eq(log, ["deep:enter", "cov:enter", "cov:leave"])
  assert_true(held.watched(), msg="covered keeps signal holds watched")
  assert_eq(unheld.val, 0)

  // Mutate held while covered: must NOT re-read.
  t.event(32.0, fn() { held.set(2) })
  t.frame(300.0, 200.0, now=32.0) |> ignore
  assert_eq(reads.val, reads_before, msg="0 re-reads while covered")

  // 2. Upgrade `covered -> deep` (`keeps_holds` -> false): `cov` must NOT double-leave, `deep` leaves once, holds drop.
  t.event(48.0, fn() {
    holding.set(false)
    // Trigger each re-evaluation so each_kept_settle upgrades covered -> deep.
    kept.set(["a", "x"])
  })
  t.frame(300.0, 200.0, now=48.0) |> ignore
  assert_eq(log, ["deep:enter", "cov:enter", "cov:leave", "deep:leave"])
  assert_false(held.watched(), msg="deep drops signal holds")
  assert_eq(unheld.val, 1)

  // Mutate held while deep: still 0 re-reads and 0 re-subscriptions.
  t.event(64.0, fn() { held.set(99) })
  t.frame(300.0, 200.0, now=64.0) |> ignore
  assert_eq(reads.val, reads_before, msg="0 re-reads while deep")
  assert_false(held.watched())

  // 3. Wake from `covered -> deep`: both hooks wake exactly once (FIFO), and binding re-reads latest value 99!
  t.event(80.0, fn() { keys.set(["a"]) })
  t.frame(300.0, 200.0, now=80.0) |> ignore
  assert_eq(log, ["deep:enter", "cov:enter", "cov:leave", "deep:leave", "deep:enter", "cov:enter"])
  assert_true(held.watched(), msg="wake restores signal subscription after covered -> deep")
  assert_eq(reads.val, reads_before + 1)
  assert_eq(t.drawn().filter(fn(d) { d.words != "" }).map(fn(d) { d.words }), ["v=99"])
}

///|
test "rest state machine: nested parking pool propagates outer deep onto inner covered and restores inner covered on outer wake" {
  let outer_keys = @signals.signal(["outer"], same=fn(a, b) { a == b })
  let outer_kept = @signals.signal(["outer"], same=fn(a, b) { a == b })
  let inner_keys = @signals.signal(["inner"], same=fn(a, b) { a == b })
  let inner_kept = @signals.signal(["inner"], same=fn(a, b) { a == b })
  let held = @signals.signal(1, same=fn(a, b) { a == b })
  let unheld = Ref(0)
  held.on_unwatched(fn() { unheld.val += 1 })
  let log : Array[String] = []
  let t = Tree::new(fn(root) {
    root.each(
      at_once=true,
      fn() { outer_keys.get() },
      fn(k) { k },
      keeps=fn() { outer_kept.get() },
      fn(ov, _) {
        ov.when_active(fn() {
          log.push("outer:enter")
          fn() { log.push("outer:leave") }
        })
        |> ignore
        ov.each(
          at_once=true,
          fn() { inner_keys.get() },
          fn(k) { k },
          keeps=fn() { inner_kept.get() },
          keeps_holds=fn(_) { true },
          fn(iv, _) {
            iv
            .when_active(while_covered=false, fn() {
              log.push("inner-deep:enter")
              fn() { log.push("inner-deep:leave") }
            })
            .when_active(while_covered=true, fn() {
              log.push("inner-cov:enter")
              fn() { log.push("inner-cov:leave") }
            })
            .height(Is(Some(20.0)))
            .words(By(fn() { "h=\{held.get()}" }))
            |> ignore
          },
        )
      },
    )
  })
  t.frame(300.0, 200.0, now=0.0) |> ignore
  assert_eq(log, ["outer:enter", "inner-deep:enter", "inner-cov:enter"])
  assert_true(held.watched())

  // 1. Inner enters covered (`keeps_holds=true`): only `inner-cov` leaves; `inner-deep` & holds remain active.
  t.event(16.0, fn() { inner_keys.set([]) })
  t.frame(300.0, 200.0, now=16.0) |> ignore
  assert_eq(log, ["outer:enter", "inner-deep:enter", "inner-cov:enter", "inner-cov:leave"])
  assert_true(held.watched())

  // 2. Outer enters deep park: propagates outer deep onto inner covered entry BEFORE outer hooks rest (children -> parent)!
  //    `inner-deep` leaves before `outer` leaves, holds drop, and `inner-cov` does NOT double-leave.
  t.event(32.0, fn() { outer_keys.set([]) })
  t.frame(300.0, 200.0, now=32.0) |> ignore
  assert_eq(log, ["outer:enter", "inner-deep:enter", "inner-cov:enter", "inner-cov:leave", "inner-deep:leave", "outer:leave"])
  assert_false(held.watched(), msg="outer deep drops inner covered entry holds")
  assert_eq(unheld.val, 1)

  // 3. Outer wakes: removes only outer deep reason -> `outer` and `inner-deep` wake, while `inner-cov` stays asleep!
  t.event(48.0, fn() { outer_keys.set(["outer"]) })
  t.frame(300.0, 200.0, now=48.0) |> ignore
  assert_eq(
    log,
    [
      "outer:enter",
      "inner-deep:enter",
      "inner-cov:enter",
      "inner-cov:leave",
      "inner-deep:leave",
      "outer:leave",
      "outer:enter",
      "inner-deep:enter",
    ],
  )
  assert_false(held.watched(), msg="inner covered entry stays resting while still covered")

  // 4. Inner wakes: `inner-cov` wakes and holds re-subscribe.
  t.event(64.0, fn() {
    held.set(7)
    inner_keys.set(["inner"])
  })
  t.frame(300.0, 200.0, now=64.0) |> ignore
  assert_eq(
    log,
    [
      "outer:enter",
      "inner-deep:enter",
      "inner-cov:enter",
      "inner-cov:leave",
      "inner-deep:leave",
      "outer:leave",
      "outer:enter",
      "inner-deep:enter",
      "inner-cov:enter",
    ],
  )
  assert_true(held.watched())
  assert_eq(t.drawn().filter(fn(d) { d.words != "" }).map(fn(d) { d.words }), ["h=7"])
}

///|
test "rest state machine: strict sleep (LIFO per node, child -> parent) and wake (parent -> child, FIFO per node, hooks before bindings) + no double-rest on evict" {
  let log : Array[String] = []
  let sig = @signals.signal(0, same=fn(a, b) { a == b })
  let holder : Ref[View?] = Ref(None)
  let parent_v : Ref[View?] = Ref(None)
  let t = Tree::new(fn(root) {
    root.box(fn(h) {
      holder.val = Some(h)
      h.box(fn(p) {
        parent_v.val = Some(p)
        p.on_rest(fn() { log.push("p:hook1:rest") }, wake=fn() { log.push("p:hook1:wake") }) |> ignore
        p.on_rest(fn() { log.push("p:hook2:rest") }, wake=fn() { log.push("p:hook2:wake") }) |> ignore
        p.reacts(fn() { sig.get() }, fn(v) { log.push("p:bind:\{v}") }, at_start=false)
        p.box(fn(c) {
          c.on_rest(fn() { log.push("c:hook1:rest") }, wake=fn() { log.push("c:hook1:wake") }) |> ignore
          c.on_rest(fn() { log.push("c:hook2:rest") }, wake=fn() { log.push("c:hook2:wake") }) |> ignore
          c.reacts(fn() { sig.get() }, fn(v) { log.push("c:bind:\{v}") }, at_start=false)
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.frame(300.0, 200.0, now=0.0) |> ignore
  let h = holder.val.unwrap()
  let p = parent_v.val.unwrap()

  // Park: post-order hooks (child LIFO -> parent LIFO).
  let wake : Ref[() -> Unit] = Ref(fn() {  })
  t.event(16.0, fn() { wake.val = h.park(p) })
  t.frame(300.0, 200.0, now=16.0) |> ignore
  assert_eq(log, ["c:hook2:rest", "c:hook1:rest", "p:hook2:rest", "p:hook1:rest"])

  // Change signal while parked: 0 bindings fire.
  log.clear()
  t.event(32.0, fn() { sig.set(1) })
  t.frame(300.0, 200.0, now=32.0) |> ignore
  assert_eq(log, [])

  // Wake: pre-order (parent hooks FIFO -> parent bindings -> child hooks FIFO -> child bindings).
  t.event(48.0, fn() {
    h.take_in(p)
    (wake.val)()
  })
  t.frame(300.0, 200.0, now=48.0) |> ignore
  assert_eq(log, ["p:hook1:wake", "p:hook2:wake", "p:bind:1", "c:hook1:wake", "c:hook2:wake", "c:bind:1"])

  // Park again, then evict (let_go) while parked: hooks must NOT be called a second time, and calling stale wake is a no-op!
  log.clear()
  let wake2 : Ref[() -> Unit] = Ref(fn() {  })
  t.event(64.0, fn() { wake2.val = h.park(p) })
  t.frame(300.0, 200.0, now=64.0) |> ignore
  assert_eq(log, ["c:hook2:rest", "c:hook1:rest", "p:hook2:rest", "p:hook1:rest"])

  log.clear()
  let when_active_leaves = Ref(0)
  p.when_active(fn() { fn() { when_active_leaves.val += 1 } }) |> ignore
  t.event(80.0, fn() {
    p.let_go()
    (wake2.val)()
  })
  t.frame(300.0, 200.0, now=80.0) |> ignore
  // `View::on_rest` runs once on disposal (cleaning up any untracked computed re-dirtied while parked);
  // stale `wake2()` after `let_go()` must be a no-op, and `when_active` registered while parked never double-leaves.
  assert_eq(log, ["c:hook2:rest", "c:hook1:rest", "p:hook2:rest", "p:hook1:rest"])
  assert_eq(when_active_leaves.val, 0, msg="when_active registered while parked never leaves on disposal")
}

///|
test "rest state machine: parked node with untracked computed re-read while parked still disposes it on let_go while when_active stays 1:1" {
  let keys = @signals.signal(["p"], same=fn(a, b) { a == b })
  let kept = @signals.signal(["p"], same=fn(a, b) { a == b })
  let src = @signals.signal(1, same=fn(a, b) { a == b })
  let unheld = Ref(0)
  src.on_unwatched(fn() { unheld.val += 1 })
  let read = @signals.computed(fn(_) { src.get() }, same=fn(a, b) { a == b })
  let leaves = Ref(0)
  let t = Tree::new(fn(root) {
    root.each(
      at_once=true,
      fn() { keys.get() },
      fn(k) { k },
      keeps=fn() { kept.get() },
      keeps_holds=fn(_) { false },
      fn(p, _) {
        p.on_rest(fn() { if !read.watched() { read.dispose() } }) |> ignore
        p.when_active(fn() { fn() { leaves.val += 1 } }) |> ignore
        p.height(Is(Some(20.0))).words(By(fn() { "v=\{read.get()}" })) |> ignore
      },
    )
  })
  t.frame(300.0, 200.0, now=0.0) |> ignore
  assert_true(src.watched())
  // Park `p` into deep sleep: bindings rest, `on_rest` disposes `read`, `when_active` leaves once.
  t.event(16.0, fn() { keys.set([]) })
  t.frame(300.0, 200.0, now=16.0) |> ignore
  assert_false(src.watched(), msg="park releases computed subscription (read.watched=\{read.watched()}, leaves=\{leaves.val})")
  assert_eq(leaves.val, 1)
  // Simulate `chat_read_left` reading `read.get()` untracked while `p` is parked, re-attaching `read` to `src`.
  @signals.untracked(fn() { read.get() }) |> ignore
  assert_true(src.watched(), msg="untracked read while parked re-attaches computed")
  // Evicting/disposing `p` must still run `on_rest` to dispose `read`, while `when_active` must NOT double-leave!
  t.event(32.0, fn() { kept.set([]) })
  t.frame(300.0, 200.0, now=32.0) |> ignore
  assert_false(src.watched(), msg="let_go runs on_rest cleanup to release re-attached computed")
  assert_eq(leaves.val, 1, msg="when_active strictly enforces 1:1 leave without double-leave on let_go")
}

///|
test "rest state machine: registration while asleep, View::rests(), detached live node, and synchronous re-entrancy in enter" {
  let log : Array[String] = []
  let holder : Ref[View?] = Ref(None)
  let attached : Ref[View?] = Ref(None)
  let flight : Ref[View?] = Ref(None)
  let reentrant : Ref[View?] = Ref(None)
  let t = Tree::new(fn(root) {
    root.box(fn(h) {
      holder.val = Some(h)
      h.box(fn(a) { attached.val = Some(a) }) |> ignore
      h.box(fn(f) { flight.val = Some(f) }) |> ignore
      h.box(fn(r) { reentrant.val = Some(r) }) |> ignore
    })
    |> ignore
  })
  t.frame(300.0, 200.0, now=0.0) |> ignore
  let h = holder.val.unwrap()
  let a = attached.val.unwrap()
  let f = flight.val.unwrap()
  let r = reentrant.val.unwrap()

  // 1. `View::rests()` keeps `a` attached (parent >= 0) while putting it in `rest_roots`:
  //    registering `when_active` while resting must defer `enter` until wake!
  let wake_a = a.rests()
  a.when_active(fn() {
    log.push("a:enter")
    fn() { log.push("a:leave") }
  })
  |> ignore
  assert_eq(log, [], msg="hook registered during View::rests() must not enter until wake")
  wake_a()
  assert_eq(log, ["a:enter"])

  // 2. Detached live node (`park(..., rest=false)` simulating shared-element flight copy):
  //    not in `rest_roots`, so `when_active` enters immediately!
  log.clear()
  h.park(f, rest=false) |> ignore
  f.when_active(fn() {
    log.push("f:enter")
    fn() { log.push("f:leave") }
  })
  |> ignore
  assert_eq(log, ["f:enter"], msg="detached live node outside rest_roots is active")
  f.let_go()
  assert_eq(log, ["f:enter", "f:leave"])

  // 3. Synchronous park inside `enter`: returned `leave` runs immediately (strict 1:1)!
  log.clear()
  let wake_r : Ref[() -> Unit] = Ref(fn() {  })
  r.when_active(fn() {
    log.push("r:enter")
    wake_r.val = h.park(r)
    fn() { log.push("r:leave") }
  })
  |> ignore
  assert_eq(log, ["r:enter", "r:leave"], msg="synchronous park inside enter runs leave immediately 1:1")
  // Dispose while parked: no second leave!
  log.clear()
  r.let_go()
  assert_eq(log, [])
}

///|
test "park-aware timers: at_moment(while_active=true) & while_active_every clear timeline while parked, 0 ticks across periods, <=1 tick on wake" {
  let holder : Ref[View?] = Ref(None)
  let page : Ref[View?] = Ref(None)
  let ticks : Array[Double] = []
  let every_ticks : Array[Double] = []
  let no_wake_ticks : Array[Double] = []
  let t = Tree::new(sources=true, fn(root) {
    root.box(fn(h) {
      holder.val = Some(h)
      h.box(fn(p) {
        page.val = Some(p)
        p.at_moment_active(
          100.0,
          fn() { ticks.push(p.cause_at()) },
          later=true,
        )
        |> ignore
        p.while_active_every(100.0, fn() { every_ticks.push(p.cause_at()) }, later=true, run_on_wake=true) |> ignore
        p.while_active_every(100.0, fn() { no_wake_ticks.push(p.cause_at()) }, later=true, run_on_wake=false) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  let frame = fn(at : Double) {
    t.at(at)
    t.frame(300.0, 200.0, now=at) |> ignore
  }
  frame(0.0)
  let h = holder.val.unwrap()
  let p = page.val.unwrap()
  assert_eq(t.subtree_timeline_count(p), 3, msg="3 active timers on timeline (including later=true)")

  // Park at t=50: all 3 timeline entries immediately removed!
  let wake : Ref[() -> Unit] = Ref(fn() {  })
  t.event(50.0, fn() { wake.val = h.park(p) })
  frame(50.0)
  assert_eq(t.subtree_timeline_count(p), 0, msg="parked subtree must own 0 timeline entries (including later=true)")

  // Advance fake clock across 5 periods (100, 200, 300, 400, 500, 550): 0 ticks!
  frame(250.0)
  frame(550.0)
  assert_eq(ticks, [])
  assert_eq(every_ticks, [])
  assert_eq(no_wake_ticks, [])
  assert_eq(t.subtree_timeline_count(p), 0)

  // Wake at t=550: at_moment & run_on_wake=true fire at most ONCE at 550; run_on_wake=false waits until 650!
  t.event(550.0, fn() {
    h.take_in(p)
    (wake.val)()
  })
  frame(550.0)
  assert_eq(ticks, [550.0])
  assert_eq(every_ticks, [550.0])
  assert_eq(no_wake_ticks, [])
  assert_eq(t.subtree_timeline_count(p), 2, msg="only the two periodic timers remain (at_moment finished)")

  // Advance to 650: both periodic timers fire once cleanly (no duplicates!).
  frame(650.0)
  assert_eq(every_ticks, [550.0, 650.0])
  assert_eq(no_wake_ticks, [650.0])
  assert_eq(t.subtree_timeline_count(p), 2)
}

///|
test "park-aware timer: callback synchronously parking self never reschedules at tail" {
  let holder : Ref[View?] = Ref(None)
  let page : Ref[View?] = Ref(None)
  let fired = Ref(0)
  let t = Tree::new(sources=true, fn(root) {
    root.box(fn(h) {
      holder.val = Some(h)
      h.box(fn(p) {
        page.val = Some(p)
        p.while_active_every(50.0, fn() {
          fired.val += 1
          h.park(p) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  let frame = fn(at : Double) {
    t.at(at)
    t.frame(300.0, 200.0, now=at) |> ignore
  }
  frame(0.0)
  let p = page.val.unwrap()
  assert_eq(t.subtree_timeline_count(p), 1)
  frame(50.0)
  assert_eq(fired.val, 1)
  assert_eq(t.subtree_timeline_count(p), 0, msg="callback that parked self must leave 0 timers on timeline")
  frame(300.0)
  assert_eq(fired.val, 1)
}

///|
test "View::pick(keeps=true, keeps_max=4, pin, keep_if, on_take): exact non-pin quota, pin exclusion, keep_if drop, sync on_take before wake" {
  let key = @signals.signal("overview", same=fn(a, b) { a == b })
  let keep_temp = Ref(false)
  let made : Map[String, Int] = Map([])
  let nodes : Map[String, View] = Map([])
  let events : Array[String] = []
  let t = Tree::new(fn(root) {
    root.pick_kept(
      at_once=true,
      fn() { key.get() },
      fn(v, k) {
        made[k] = made.get(k).unwrap_or(0) + 1
        nodes[k] = v
        v.on_rest(fn() { events.push("rest:\{k}") }, wake=fn() { events.push("wake:\{k}") }) |> ignore
        v.height(Is(Some(30.0))).words(Is(k)) |> ignore
      },
      keeps=true,
      keeps_max=4,
      pin=fn(k) { k == "overview" },
      keep_if=fn(k) { if k == "temp" { keep_temp.val } else { true } },
      on_take=fn(v, k) { events.push("take:\{k}@\{v.cause_at()}") },
    )
  })
  t.frame(300.0, 200.0, now=0.0) |> ignore
  let n_ov = nodes["overview"]

  // Visit p1, p2, p3, p4: total non-pin = 4 (3 parked + 1 active p4) + pinned overview.
  t.event(10.0, fn() { key.set("p1") })
  t.frame(300.0, 200.0, now=10.0) |> ignore
  t.event(20.0, fn() { key.set("p2") })
  t.frame(300.0, 200.0, now=20.0) |> ignore
  t.event(30.0, fn() { key.set("p3") })
  t.frame(300.0, 200.0, now=30.0) |> ignore
  t.event(40.0, fn() { key.set("p4") })
  t.frame(300.0, 200.0, now=40.0) |> ignore
  assert_true(n_ov.alive() && nodes["p1"].alive() && nodes["p2"].alive() && nodes["p3"].alive() && nodes["p4"].alive())

  // Return to pinned overview: active_non_pin = 0, so ALL 4 non-pin profiles (p1..p4) stay parked!
  // Also verify `on_take` fires synchronously BEFORE `wake:overview` with cause moment 50.0.
  events.clear()
  t.event(50.0, fn() { key.set("overview") })
  t.frame(300.0, 200.0, now=50.0) |> ignore
  assert_eq(events, ["rest:p4", "take:overview@50", "wake:overview"])
  assert_true(n_ov.alive() && nodes["p1"].alive() && nodes["p2"].alive() && nodes["p3"].alive() && nodes["p4"].alive())

  // Visit transient `temp` (`keep_if == false`) while p1..p4 are parked:
  // `temp` must NOT consume `keeps_max` quota or evict `p1`, and leaving `temp` drops it immediately!
  t.event(55.0, fn() { key.set("temp") })
  t.frame(300.0, 200.0, now=55.0) |> ignore
  let n_temp = nodes["temp"]
  assert_true(n_temp.alive())
  assert_true(nodes["p1"].alive() && nodes["p2"].alive() && nodes["p3"].alive() && nodes["p4"].alive(), msg="transient keep_if=false must not evict parked branches")
  t.event(58.0, fn() { key.set("overview") })
  t.frame(300.0, 200.0, now=58.0) |> ignore
  assert_false(n_temp.alive(), msg="keep_if=false branch dropped on leave instead of parked")
  assert_true(nodes["p1"].alive() && nodes["p2"].alive() && nodes["p3"].alive() && nodes["p4"].alive())

  // Open p5 (non-pin) during event: active_non_pin = 1, max parked non-pin = 3 -> evicts oldest non-pin p1 (never overview!).
  // Eviction retires `p1` immediately via `retire_parked` (alive == false, parked_retired_count > 0) and defers slot recycling until next idle frame.
  let let_go_before = t.work.let_go
  t.event(60.0, fn() { key.set("p5") })
  assert_true(n_ov.alive(), msg="pinned overview must never be evicted")
  assert_false(nodes["p1"].alive(), msg="LRU non-pin p1 evicted immediately")
  assert_true(t.parked_retired_count() > 0, msg="eviction queued in parked_garbage before idle recycle")
  assert_eq(t.work.let_go, let_go_before, msg="slot recycling deferred until idle frame")
  t.frame(300.0, 200.0, now=60.0) |> ignore
  assert_eq(t.parked_retired_count(), 0, msg="idle frame drains parked_garbage")
  assert_true(t.work.let_go > let_go_before, msg="slot recycling completed on idle frame")
  assert_true(nodes["p2"].alive() && nodes["p3"].alive() && nodes["p4"].alive() && nodes["p5"].alive())
}

///|
test "chained at_moment(while_active=true) 20 times does not leak View::owns entries on the node" {
  let page : Ref[View?] = Ref(None)
  let fired = Ref(0)
  let t = Tree::new(fn(root) {
    root.box(fn(p) {
      page.val = Some(p)
      fn chain(n : Int) -> Unit {
        if n <= 0 {
          return
        }
        p.at_moment_active(
          p.cause_at() + 10.0,
          fn() {
            fired.val += 1
            chain(n - 1)
          },
          later=true,
        )
        |> ignore
      }
      chain(20)
    })
    |> ignore
  })
  let frame = fn(at : Double) {
    t.at(at)
    t.frame(300.0, 200.0, now=at) |> ignore
  }
  frame(0.0)
  let p = page.val.unwrap()
  let baseline_owned = p.owned_count()
  for i in 1..<=20 {
    frame(i.to_double() * 10.0)
  }
  assert_eq(fired.val, 20)
  // After all 20 chained timers finish, only the single per-node rest_hooks `owns` entry remains (no leak!).
  assert_true(p.owned_count() <= baseline_owned, msg="owned_count must not grow across chained at_moment(while_active=true)")
}

///|
test "nested parking pool same-batch race: inner key leaves into holding and outer deep parks in the same event" {
  let outer_keys = @signals.signal(["outer"], same=fn(a, b) { a == b })
  let outer_kept = @signals.signal(["outer"], same=fn(a, b) { a == b })
  let inner_keys = @signals.signal(["inner"], same=fn(a, b) { a == b })
  let inner_kept = @signals.signal(["inner"], same=fn(a, b) { a == b })
  let held = @signals.signal(1, same=fn(a, b) { a == b })
  let unheld = Ref(0)
  held.on_unwatched(fn() { unheld.val += 1 })
  let log : Array[String] = []
  let t = Tree::new(fn(root) {
    root.each(
      at_once=true,
      fn() { outer_keys.get() },
      fn(k) { k },
      keeps=fn() { outer_kept.get() },
      fn(ov, _) {
        ov.each(
          at_once=true,
          fn() { inner_keys.get() },
          fn(k) { k },
          keeps=fn() { inner_kept.get() },
          keeps_holds=fn(_) { true },
          fn(iv, _) {
            iv
            .when_active(while_covered=false, fn() {
              log.push("inner-deep:enter")
              fn() { log.push("inner-deep:leave") }
            })
            .when_active(while_covered=true, fn() {
              log.push("inner-cov:enter")
              fn() { log.push("inner-cov:leave") }
            })
            .height(Is(Some(20.0)))
            .words(By(fn() { "h=\{held.get()}" }))
            |> ignore
          },
        )
      },
    )
  })
  t.frame(300.0, 200.0, now=0.0) |> ignore
  assert_eq(log, ["inner-deep:enter", "inner-cov:enter"])
  assert_true(held.watched())

  // Same event batch: inner leaves into `holding` AND outer deep parks!
  t.event(16.0, fn() {
    inner_keys.set([])
    outer_keys.set([])
  })
  t.frame(300.0, 200.0, now=16.0) |> ignore
  assert_false(held.watched(), msg="same-batch outer deep must drop inner holding entry's holds")
  assert_true(log.contains("inner-deep:leave"), msg="inner-deep must rest")
  assert_true(log.contains("inner-cov:leave"), msg="inner-cov must rest")

  // Outer wakes: inner returns to covered state (`inner-deep` wakes, `inner-cov` stays asleep).
  log.clear()
  t.event(32.0, fn() { outer_keys.set(["outer"]) })
  t.frame(300.0, 200.0, now=32.0) |> ignore
  assert_eq(log, ["inner-deep:enter"])
  assert_false(held.watched())
}

///|
test "rest state machine: subtree-local wake fast path isolates parked sibling & rests() block, and falls back when inner root added while asleep" {
  let log : Array[String] = []
  let holder : Ref[View?] = Ref(None)
  let main_box : Ref[View?] = Ref(None)
  let main_child : Ref[View?] = Ref(None)
  let sib_parked : Ref[View?] = Ref(None)
  let sib_rested : Ref[View?] = Ref(None)
  let t = Tree::new(fn(root) {
    root.box(fn(h) {
      holder.val = Some(h)
      h.box(fn(m) {
        main_box.val = Some(m)
        m.when_active(fn() {
          log.push("main:enter")
          fn() { log.push("main:leave") }
        })
        |> ignore
        m.box(fn(c) {
          main_child.val = Some(c)
          c.when_active(fn() {
            log.push("child:enter")
            fn() { log.push("child:leave") }
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      h.box(fn(s1) {
        sib_parked.val = Some(s1)
        s1.when_active(fn() {
          log.push("sib_parked:enter")
          fn() { log.push("sib_parked:leave") }
        })
        |> ignore
      })
      |> ignore
      h.box(fn(s2) {
        sib_rested.val = Some(s2)
        s2.when_active(fn() {
          log.push("sib_rested:enter")
          fn() { log.push("sib_rested:leave") }
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.frame(300.0, 200.0, now=0.0) |> ignore
  let h = holder.val.unwrap()
  let m = main_box.val.unwrap()
  let c = main_child.val.unwrap()
  let s1 = sib_parked.val.unwrap()
  let s2 = sib_rested.val.unwrap()

  // Park sibling s1 and rest sibling s2 so `book.roots` is non-empty (production realistic state).
  let wake_s1 = h.park(s1)
  let wake_s2 = s2.rests()
  log.clear()

  // 1. Park and wake `m` while s1 & s2 are asleep: must hit subtree-local fast path and never wake s1/s2!
  let wake_m1 = h.park(m)
  assert_eq(log, ["child:leave", "main:leave"])
  log.clear()
  h.take_in(m)
  wake_m1()
  assert_eq(log, ["main:enter", "child:enter"], msg="waking main subtree must not wake parked sibling or rests() block")

  // 2. Park `m`, then add an inner `rests()` on `c` while `m` is asleep:
  //    `roots_added_ver` changes so waking `m` falls back to `wake_subtree_preorder` and keeps `c` asleep!
  log.clear()
  let wake_m2 = h.park(m)
  let wake_c = c.rests()
  log.clear()
  h.take_in(m)
  wake_m2()
  assert_eq(log, ["main:enter"], msg="inner rests() added while asleep must remain asleep after outer wake")

  // Releasing inner `rests()` wakes `c`; releasing s1/s2 wakes them cleanly.
  log.clear()
  wake_c()
  assert_eq(log, ["child:enter"])
  log.clear()
  h.take_in(s1)
  wake_s1()
  wake_s2()
  assert_eq(log, ["sib_parked:enter", "sib_rested:enter"])
}
