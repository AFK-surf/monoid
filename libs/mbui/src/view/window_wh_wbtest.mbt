///|
test "window_w and window_h isolate single-axis resizes and batch dual-axis resizes" {
  let w_reads = Ref(0)
  let h_reads = Ref(0)
  let wh_reads = Ref(0)
  let w_runs = Ref(0)
  let h_runs = Ref(0)
  let wh_runs = Ref(0)
  let last_w = Ref(0.0)
  let last_h = Ref(0.0)
  let last_wh = Ref((0.0, 0.0))
  let tree = Tree::new(fn(root) {
    root.reacts(
      fn() {
        w_reads.val += 1
        root.window_w()
      },
      fn(w) {
        w_runs.val += 1
        last_w.val = w
      },
    )
    root.reacts(
      fn() {
        h_reads.val += 1
        root.window_h()
      },
      fn(h) {
        h_runs.val += 1
        last_h.val = h
      },
    )
    root.reacts(
      fn() {
        wh_reads.val += 1
        root.window()
      },
      fn(wh) {
        wh_runs.val += 1
        last_wh.val = wh
      },
    )
  })
  // Reset counts after initial setup before the first frame.
  w_reads.val = 0
  h_reads.val = 0
  wh_reads.val = 0
  w_runs.val = 0
  h_runs.val = 0
  wh_runs.val = 0

  // 1) First frame: both axes change (0, 0) -> (390, 844); batched so window() runs once.
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  assert_eq(w_reads.val, 1)
  assert_eq(h_reads.val, 1)
  assert_eq(wh_reads.val, 1)
  assert_eq(w_runs.val, 1)
  assert_eq(h_runs.val, 1)
  assert_eq(wh_runs.val, 1)
  assert_eq(last_w.val, 390.0)
  assert_eq(last_h.val, 844.0)
  assert_eq(last_wh.val, (390.0, 844.0))

  // 2) Soft keyboard steps: 5 consecutive height-only frames leave window_w untouched.
  let kb_heights = [780.0, 700.0, 620.0, 540.0, 500.0]
  for i, h in kb_heights {
    tree.frame(390.0, h, now=(i + 1).to_double() * 16.0) |> ignore
  }
  assert_eq(w_reads.val, 1)
  assert_eq(w_runs.val, 1)
  assert_eq(h_reads.val, 6)
  assert_eq(h_runs.val, 6)
  assert_eq(wh_reads.val, 6)
  assert_eq(wh_runs.val, 6)
  assert_eq(last_h.val, 500.0)
  assert_eq(last_wh.val, (390.0, 500.0))

  // 3) Width-only change leaves window_h untouched.
  tree.frame(420.0, 500.0, now=96.0) |> ignore
  assert_eq(h_reads.val, 6)
  assert_eq(h_runs.val, 6)
  assert_eq(w_reads.val, 2)
  assert_eq(w_runs.val, 2)
  assert_eq(wh_reads.val, 7)
  assert_eq(wh_runs.val, 7)
  assert_eq(last_w.val, 420.0)
  assert_eq(last_wh.val, (420.0, 500.0))

  // 4) Diagonal resize: both axes change in one frame; window() runs +1 (not +2).
  tree.frame(800.0, 600.0, now=112.0) |> ignore
  assert_eq(w_reads.val, 3)
  assert_eq(w_runs.val, 3)
  assert_eq(h_reads.val, 7)
  assert_eq(h_runs.val, 7)
  assert_eq(wh_reads.val, 8)
  assert_eq(wh_runs.val, 8)
  assert_eq(last_w.val, 800.0)
  assert_eq(last_h.val, 600.0)
  assert_eq(last_wh.val, (800.0, 600.0))
  tree.dispose()
}

///|
test "sizes_told deduplicates in O(N), clears size_seen, and keeps nodes added during end_batch" {
  let node_a : Ref[View?] = Ref(None)
  let node_b : Ref[View?] = Ref(None)
  let size_a : Ref[(Double, Double)?] = Ref(None)
  let size_b : Ref[(Double, Double)?] = Ref(None)
  let b_width = @signals.signal(120.0, same=fn(a, b) { a == b })
  let tree = Tree::new(fn(root) {
    root.box(fn(a) {
      node_a.val = Some(a)
      a.width(Is(Some(100.0))).height(Is(Some(40.0))) |> ignore
      a.reacts(fn() { a.laid_size_told() }, fn(sz) { size_a.val = sz })
    })
    |> ignore
    root.show(
      fn() {
        match node_a.val {
          Some(a) => a.laid_size_told() is Some(_)
          None => false
        }
      },
      fn(s) {
        s.box(fn(b) {
          node_b.val = Some(b)
          b.width(By(fn() { Some(b_width.get()) })).height(Is(Some(50.0))) |> ignore
          b.reacts(fn() { b.laid_size_told() }, fn(sz) { size_b.val = sz })
        })
        |> ignore
      },
    )
  })
  let a = node_a.val.unwrap()
  // Push duplicate entries for node `a` into `tree.sized` to verify O(N) deduplication.
  tree.sized.push(a.at)
  tree.sized.push(a.at)

  tree.frame(390.0, 844.0, now=0.0) |> ignore
  assert_eq(size_a.val, Some((100.0, 40.0)))
  assert_true(!tree.nodes[a.at].size_seen)

  // Ensure node `a` appears exactly once in `tree.sized`.
  let mut a_count = 0
  for at in tree.sized {
    if at == a.at {
      a_count += 1
    }
  }
  assert_eq(a_count, 1)

  // Node `b` was mounted during `end_batch` and must receive its laid size on the next pass/frame.
  tree.frame(390.0, 844.0, now=16.0) |> ignore
  let b = node_b.val.unwrap()
  assert_eq(size_b.val, Some((120.0, 50.0)))
  assert_true(!tree.nodes[b.at].size_seen)

  // Subsequent layout change on `b` continues to notify `size_b`.
  tree.event(32.0, fn() { b_width.set(160.0) })
  tree.frame(390.0, 844.0, now=32.0) |> ignore
  assert_eq(size_b.val, Some((160.0, 50.0)))
  assert_true(!tree.nodes[b.at].size_seen)
  tree.dispose()
}
