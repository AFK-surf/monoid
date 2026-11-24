///|
test "once_laid_out cycle in Tree::laid_out stops within bound" {
  let runs = Ref(0)
  let escaped = Ref(false)
  let w = @signals.signal(100.0, same=fn(a, b) { a == b })
  let t = Tree::new(fn(root) {
    root.box(fn(b) {
      b.width(By(fn() { Some(w.get()) })).height(Is(Some(40.0))) |> ignore
    })
    |> ignore
  })
  fn schedule() {
    t.once_laid_out(fn() {
      runs.val += 1
      if runs.val >= 200 {
        escaped.val = true
        return
      }
      w.set(if w.untracked() == 100.0 { 120.0 } else { 100.0 })
      schedule()
    })
  }
  schedule()
  t.frame(300.0, 300.0) |> ignore
  assert_false(
    escaped.val,
    msg="Tree::laid_out must stop a once_laid_out recursion cycle before 200 runs (runs=\{runs.val})",
  )
  assert_true(
    runs.val <= laid_passes_most + 1,
    msg="once_laid_out cycle runs stay within laid_passes_most (runs=\{runs.val})",
  )
  t.dispose()
}

///|
test "sizes_told oscillation in Tree::laid_out stops within bound" {
  let runs = Ref(0)
  let escaped = Ref(false)
  let w = @signals.signal(100.0, same=fn(a, b) { a == b })
  let t = Tree::new(fn(root) {
    root.box(fn(b) {
      b.width(By(fn() { Some(w.get()) })).height(Is(Some(40.0))) |> ignore
      b.reacts(fn() { b.laid_size_told() }, at_start=false, fn(sz) {
        if sz is Some((bw, _)) && !escaped.val {
          runs.val += 1
          if runs.val >= 200 {
            escaped.val = true
            return
          }
          w.set(if bw < 110.0 { 120.0 } else { 100.0 })
        }
      })
    })
    |> ignore
  })
  t.frame(300.0, 300.0) |> ignore
  assert_false(
    escaped.val,
    msg="Tree::laid_out must stop a sizes_told oscillation cycle before 200 runs (runs=\{runs.val})",
  )
  assert_true(
    runs.val <= laid_passes_most + 1,
    msg="sizes_told cycle runs stay within laid_passes_most (runs=\{runs.val})",
  )
  t.dispose()
}

///|
test "outs_told oscillation in Tree::laid_out stops within bound" {
  let runs = Ref(0)
  let escaped = Ref(false)
  let w = @signals.signal(80.0, same=fn(a, b) { a == b })
  let t = Tree::new(fn(root) {
    root.box(fn(r) {
      r.row(Is(true)).width(By(fn() { Some(w.get()) })).height(Is(Some(40.0))).fits(Is(true)) |> ignore
      r.box(fn(a) { a.width(Is(Some(60.0))).height(Is(Some(20.0))) |> ignore }) |> ignore
      r.box(fn(b) {
        b.width(Is(Some(60.0))).height(Is(Some(20.0))).drops(Is(1)) |> ignore
        b.reacts(fn() { b.left_out() }, at_start=false, fn(out) {
          if !escaped.val {
            runs.val += 1
            if runs.val >= 200 {
              escaped.val = true
              return
            }
            w.set(if out { 160.0 } else { 80.0 })
          }
        })
      })
      |> ignore
    })
    |> ignore
  })
  t.frame(300.0, 300.0) |> ignore
  assert_false(
    escaped.val,
    msg="Tree::laid_out must stop an outs_told oscillation cycle before 200 runs (runs=\{runs.val})",
  )
  assert_true(
    runs.val <= laid_passes_most + 1,
    msg="outs_told cycle runs stay within laid_passes_most (runs=\{runs.val})",
  )
  t.dispose()
}
