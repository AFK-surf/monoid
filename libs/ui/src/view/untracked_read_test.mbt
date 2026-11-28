///|
#callsite(autofill(loc))
fn read_test_loc(loc~ : SourceLoc) -> SourceLoc {
  loc
}

///|
test "box reports bare reads for each reactive value and deduplicates repeated reads" {
  let signal = @signals.signal(1)
  let computed = @signals.computed(fn(_) { signal.get() })
  let derived = @signals.derived_signal(fn(_) { computed.get() })
  let optimistic = @signals.optimistic(fn() { derived.get() })
  let signal_at = read_test_loc()
  let computed_at = read_test_loc()
  let derived_at = read_test_loc()
  let optimistic_at = read_test_loc()
  let part = read_test_loc()
  let tree = @view.Tree::new(sources=true, fn(v) {
    v.box(loc=signal_at, made_for=part, fn(_) {
      signal.get() |> ignore
      signal.get() |> ignore
    }) |> ignore
    v.box(loc=computed_at, fn(_) { computed.get() |> ignore }) |> ignore
    v.box(loc=derived_at, fn(_) { derived.get() |> ignore }) |> ignore
    v.box(loc=optimistic_at, fn(_) { optimistic.get() |> ignore }) |> ignore
  })
  let faults = tree.untracked_read_faults()
  let places = [signal_at, computed_at, derived_at, optimistic_at]
  assert_eq(faults.length(), places.length())
  let place = @view.source_place(signal_at)
  assert_true(faults[0].contains("at \{place} (for \{@view.source_place(part)})"), msg=faults[0])
  for i, fault in faults {
    assert_true(fault.contains("at \{@view.source_place(places[i])}"), msg=fault)
    assert_true(fault.has_prefix("[STRICT_READ_UNTRACKED]"), msg=fault)
    assert_true(fault.contains("Fix:"), msg=fault)
  }
  tree.dispose()
  assert_eq(tree.untracked_read_faults(), [])
  assert_false(@view.untracked_read_marks_left())
}

///|
test "tracked reads, explicit snapshots and actions inside a box stay quiet" {
  let signal = @signals.signal(1)
  let other = @signals.signal(2)
  let seen : Array[Int] = []
  let tree = @view.Tree::new(sources=true, fn(root) {
    root.box(fn(v) {
      v.words(By(fn() { signal.get().to_string() })) |> ignore
      v.reacts(fn() { signal.get() }, fn(_) { seen.push(other.get()) })
      v.show(fn() { signal.get() > 0 }, fn(_) { seen.push(other.get()) })
      v.pick(fn() { signal.get() }, fn(_, n) { seen.push(n + other.get()) })
      v.each(fn() { [signal.get()] }, fn(n) { n }, fn(_, n) { seen.push(n.get()) })
      seen.push(signal.untracked())
      @signals.untracked(fn() { seen.push(signal.get()) })
    }) |> ignore
  })
  assert_eq(seen, [2, 2, 3, 1, 1, 1])
  assert_eq(tree.untracked_read_faults(), [])
  tree.dispose()
}

///|
test "nested boxes restore the parent read context and unsourced trees record nothing" {
  let signal = @signals.signal(1)
  let parent = read_test_loc()
  let child = read_test_loc()
  let make = fn(root : @view.View) {
    root.box(loc=parent, fn(v) {
      v.box(loc=child, fn(_) { signal.get() |> ignore }) |> ignore
      signal.get() |> ignore
    }) |> ignore
  }
  let tree = @view.Tree::new(sources=true, make)
  let other = @view.Tree::new(sources=false, make)
  assert_eq(other.untracked_read_faults(), [])
  let faults = tree.untracked_read_faults()
  assert_eq(faults.length(), 2)
  assert_true(faults[0].contains("at \{@view.source_place(child)};"), msg=faults[0])
  assert_true(faults[1].contains("at \{@view.source_place(parent)};"), msg=faults[1])
  assert_false(@view.untracked_read_marks_left())
  @view.untracked_read_reset()
  assert_eq(tree.untracked_read_faults(), [])
  tree.dispose()
  other.dispose()
}

///|
test "untracked read bars count distinct non-test places per file and default to zero" {
  let file = "example/src/read.mbt"
  let first = file + ":10"
  let second = file + ":20"
  assert_eq(@view.untracked_read_fault(first, [], "fault"), Some("fault"))
  @view.untracked_read_known([(file, 1)])
  defer @view.untracked_read_known([(file, 0)])
  assert_eq(@view.untracked_read_fault(first, [], "fault"), None)
  assert_eq(@view.untracked_read_fault(first, [first], "fault"), None)
  assert_eq(@view.untracked_read_fault(second, [first], "fault"), Some("fault"))
  assert_eq(@view.untracked_read_fault("example/src/read_test.mbt:1", [], "fault"), None)
  assert_eq(@view.untracked_read_fault("example/src/read_wbtest.mbt:1", [], "fault"), None)
  assert_eq(@view.untracked_read_fault("example/src/read_test.pion:1", [], "fault"), None)
  assert_eq(@view.clock_read_fault("drawn_at", "example/src/read_test.pion:1", []), None)
}

///|
test "effect_in_view_faults flags bare @signals.effect in View construction and allows reacts/By/owns" {
  let sig = @signals.signal(0)
  let eff_box_loc = read_test_loc()
  let eff_root_loc = read_test_loc()
  let eff_show_loc = read_test_loc()
  let tree = @view.Tree::new(sources=true, fn(root) {
    @signals.effect(fn() { sig.get() |> ignore }, loc=eff_root_loc) |> ignore
    root.box(fn(v) {
      @signals.effect(fn() { sig.get() |> ignore }, loc=eff_box_loc) |> ignore
      // Allowed alternatives must not trigger [EFFECT_IN_VIEW]:
      v.words(By(fn() { sig.get().to_string() })) |> ignore
      v.reacts(fn() { sig.get() }, fn(_) { () })
      v.owns(fn() { () }) |> ignore
      v.show(fn() { true }, fn(_inner) {
        @signals.effect_cleanup(fn() { fn() { () } }, loc=eff_show_loc) |> ignore
      })
    })
    |> ignore
  })
  let faults = tree.effect_in_view_faults()
  assert_eq(faults.length(), 3, msg=faults.join("\n"))
  assert_true(faults[0].has_prefix("[EFFECT_IN_VIEW]"), msg=faults[0])
  assert_true(faults[0].contains(@view.source_place(eff_root_loc)), msg=faults[0])
  assert_true(faults[1].contains(@view.source_place(eff_box_loc)), msg=faults[1])
  assert_true(faults[2].contains(@view.source_place(eff_show_loc)), msg=faults[2])
  assert_false(@view.untracked_read_marks_left())
  tree.dispose()
  assert_eq(tree.effect_in_view_faults(), [])
}

///|
test "scroll_each_faults flags non-virtualized scrolls+each over limit and excludes list_reused" {
  let items : Array[Int] = []
  for i in 0..<55 {
    items.push(i)
  }
  let s1 = @view.Scroll::new()
  let each_loc = read_test_loc()
  let tree = @view.Tree::new(sources=true, fn(root) {
    root.box(fn(sc) {
      sc.scrolls(s1, fn(inner) {
        inner.each(fn() { items }, fn(i) { i }, fn(row, _it) {
          row.height(Is(Some(20.0))) |> ignore
        }, at_once=true, loc=each_loc)
      })
      |> ignore
    })
    |> ignore
    // Virtualized list_reused with >50 keys must NOT be flagged.
    root.box(fn(virt) {
      virt.list_reused(fn() { items }, fn(row, _k) {
        row.height(Is(Some(20.0))) |> ignore
      }, at_once=true)
      |> ignore
    })
    |> ignore
  })
  let faults = tree.scroll_each_faults(limit=50)
  assert_eq(faults.length(), 1, msg=faults.join("\n"))
  assert_true(faults[0].has_prefix("[UNVIRTUALIZED_SCROLL_EACH]"), msg=faults[0])
  assert_true(faults[0].contains("55 live items (> 50)"), msg=faults[0])
  assert_true(faults[0].contains(@view.source_place(each_loc)), msg=faults[0])
  assert_eq(tree.scroll_each_faults(limit=60), [])
  assert_eq(tree.scroll_each_faults(limit=0), [])
  tree.dispose()
}
