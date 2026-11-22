// EachKept two-phase eviction deferral (each_kept.mbt, view.mbt): evicting a parked cached subtree during an event or
// while a transition/animation is active immediately retires live subscriptions and View::owns callbacks via
// View::retire_parked() while deferring heavy slot/flex/host cleanup (parked_garbage -> free/removed) until the first
// idle frame or Tree::dispose().

///|
test "each_kept: eviction during event or active animation retires owns immediately and defers slot recycling until idle frame" {
  let clock = Ref(0.0)
  let items = @signals.signal(["a", "b"], same=fn(a, b) { a == b })
  let keeps = @signals.signal(["a", "b"], same=fn(a, b) { a == b })
  let bg = @signals.signal(0)
  let anim_on = @signals.signal(false)
  let nodes : Map[String, View] = Map([])
  let gone_count : Map[String, Int] = Map([])
  let binding_runs : Map[String, Int] = Map([])
  let tree = Tree::new(time=fn() { clock.val }, fn(root) {
    root.box(fn(anim) {
      anim
      .height(Is(Some(10.0)))
      .offset(By(fn() {
        if !anim_on.get() {
          return (0.0, 0.0)
        }
        let d = anim.drawn_while(fn(at) { at < 200.0 })
        if d == @double.infinity {
          (20.0, 0.0)
        } else {
          (d * 0.1, 0.0)
        }
      }))
      |> ignore
    })
    |> ignore
    root.each(
      fn() { items.get() },
      fn(k) { k },
      keeps=fn() { keeps.get() },
      keeps_holds=fn(_) { true },
      fn(r, item) {
        let k = item.untracked()
        nodes[k] = r
        r.owns(fn() { gone_count[k] = gone_count.get(k).unwrap_or(0) + 1 }) |> ignore
        r.box(fn(b) {
          b
          .height(Is(Some(40.0)))
          .words(By(fn() {
            binding_runs[k] = binding_runs.get(k).unwrap_or(0) + 1
            "\{item.get()}:\{bg.get()}"
          }))
          |> ignore
        })
        |> ignore
      },
    )
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore

  // Park "a" while keeping it cached with holds
  clock.val = 16.0
  tree.event(16.0, fn() { items.set(["b"]) })
  tree.frame(390.0, 844.0, now=16.0) |> ignore
  let node_a = nodes["a"]
  assert_true(node_a.alive())
  let runs_before = binding_runs.get("a").unwrap_or(0)

  // Evict "a" during an event and start an animation: owns runs immediately, slot recycling is deferred
  clock.val = 32.0
  tree.event(32.0, fn() {
    anim_on.set(true)
    keeps.set(["b"])
  })
  assert_eq(gone_count.get("a").unwrap_or(0), 1)
  assert_true(!node_a.alive())
  assert_true(tree.parked_garbage.length() > 0)
  assert_true(!tree.free.contains(node_a.at))

  // Background signal write must not wake the retired subtree, and in-motion frame keeps slots deferred
  clock.val = 48.0
  tree.event(48.0, fn() { bg.set(1) })
  tree.frame(390.0, 844.0, now=50.0) |> ignore
  assert_eq(binding_runs.get("a").unwrap_or(0), runs_before)
  assert_true(tree.parked_garbage.length() > 0)
  assert_true(!tree.free.contains(node_a.at))

  // Idle frame after animation finishes drains parked_garbage and returns node slots to free list
  clock.val = 220.0
  tree.frame(390.0, 844.0, now=220.0) |> ignore
  assert_true(tree.parked_garbage.is_empty())
  assert_true(tree.free.contains(node_a.at))
  tree.dispose()
}

///|
test "each_kept: Tree::dispose drains deferred parked_garbage cleanly" {
  let clock = Ref(0.0)
  let items = @signals.signal(["a", "b"], same=fn(a, b) { a == b })
  let keeps = @signals.signal(["a", "b"], same=fn(a, b) { a == b })
  let gone_count : Map[String, Int] = Map([])
  let tree = Tree::new(time=fn() { clock.val }, fn(root) {
    root.each(
      fn() { items.get() },
      fn(k) { k },
      keeps=fn() { keeps.get() },
      fn(r, item) {
        let k = item.untracked()
        r.owns(fn() { gone_count[k] = gone_count.get(k).unwrap_or(0) + 1 }) |> ignore
        r.box(fn(b) { b.height(Is(Some(40.0))) |> ignore }) |> ignore
      },
    )
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  clock.val = 16.0
  tree.event(16.0, fn() { items.set(["b"]) })
  tree.frame(390.0, 844.0, now=16.0) |> ignore

  clock.val = 32.0
  tree.event(32.0, fn() { keeps.set(["b"]) })
  assert_eq(gone_count.get("a").unwrap_or(0), 1)
  assert_true(tree.parked_garbage.length() > 0)

  tree.dispose()
  assert_true(tree.parked_garbage.is_empty())
}
