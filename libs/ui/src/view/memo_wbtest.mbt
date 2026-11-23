// View::memo: node-owned memoized derivation that evaluates once per change across multiple readers, stops downstream
// updates when equal, disposes on unmount, and preserves Tree::clock_read_now tracking for callers like View::alpha.

///|
test "View::memo evaluates once per change for multiple readers and cuts off equal values" {
  let src = @signals.signal(1, same=fn(a, b) { a == b })
  let memo_runs = Ref(0)
  let bind_a = Ref(0)
  let bind_b = Ref(0)
  let vals : Array[(Int, Int)] = []
  let t = Tree::new(fn(root) {
    root.box(fn(box) {
      box.width(Is(Some(100.0))).height(Is(Some(40.0))) |> ignore
      // Bucket by src / 2 so changing 2 -> 3 produces an equal value (1).
      let m = box.memo(fn() {
        memo_runs.val += 1
        src.get() / 2
      })
      box
      .offset(By(fn() {
        bind_a.val += 1
        let v = m()
        vals.push((1, v))
        (v.to_double(), 0.0)
      }))
      .drawn_off(By(fn() {
        bind_b.val += 1
        let v = m()
        vals.push((2, v))
        (0.0, v.to_double())
      }))
      |> ignore
    })
    |> ignore
  })
  t.frame(200.0, 200.0, now=0.0) |> ignore
  assert_eq(memo_runs.val, 1, msg="initial frame evaluates memo once across 2 bindings")
  assert_eq(bind_a.val, 1)
  assert_eq(bind_b.val, 1)

  // Changing 1 -> 2 changes src / 2 from 0 -> 1: memo runs once, both bindings update.
  src.set(2)
  t.frame(200.0, 200.0, now=16.0) |> ignore
  assert_eq(memo_runs.val, 2, msg="changed value evaluates memo once")
  assert_eq(bind_a.val, 2)
  assert_eq(bind_b.val, 2)

  // Changing 2 -> 3 keeps src / 2 == 1: memo recomputes once, but Eq cutoff stops both bindings.
  src.set(3)
  t.frame(200.0, 200.0, now=32.0) |> ignore
  assert_eq(memo_runs.val, 3, msg="memo recomputes on dependency change")
  assert_eq(bind_a.val, 2, msg="Eq cutoff stops first binding")
  assert_eq(bind_b.val, 2, msg="Eq cutoff stops second binding")
}

///|
test "View::memo disposes when its owning node unmounts" {
  let show = @signals.signal(true, same=fn(a, b) { a == b })
  let src = @signals.signal(10, same=fn(a, b) { a == b })
  let runs = Ref(0)
  let t = Tree::new(fn(root) {
    root.show(at_once=true, fn() { show.get() }, fn(box) {
      let m = box.memo(fn() {
        runs.val += 1
        src.get() * 2
      })
      box.width(By(fn() { Some(m().to_double()) })).height(Is(Some(20.0))) |> ignore
    })
  })
  t.frame(200.0, 200.0, now=0.0) |> ignore
  assert_eq(runs.val, 1)

  // Unmount node: memo must dispose and stop reacting to src.
  show.set(false)
  t.frame(200.0, 200.0, now=16.0) |> ignore
  src.set(20)
  t.frame(200.0, 200.0, now=32.0) |> ignore
  assert_eq(runs.val, 1, msg="disposed memo must not re-run after unmount")
}

///|
test "View::memo forwards clock_read_now so View::alpha keeps alpha_animating" {
  let a_view : Ref[View?] = Ref(None)
  let b_view : Ref[View?] = Ref(None)
  let ended = @signals.signal(false, same=fn(a, b) { a == b })
  let t = Tree::new(fn(root) {
    root.box(fn(holder) {
      holder.width(Is(Some(100.0))).height(Is(Some(100.0))) |> ignore
      holder.at_moment(200.0, fn() { ended.set(true) }) |> ignore
      let anim_alpha = holder.memo(fn() {
        let _ = ended.get()
        let now = holder.drawn_while(fn(at) { at < 200.0 })
        if now == @double.infinity {
          1.0
        } else {
          now / 200.0
        }
      })
      holder.box(fn(a) {
        a_view.val = Some(a)
        a.width(Is(Some(40.0))).height(Is(Some(40.0))).alpha(By(anim_alpha)) |> ignore
      })
      |> ignore
      holder.box(fn(b) {
        b_view.val = Some(b)
        b.width(Is(Some(40.0))).height(Is(Some(40.0))).alpha(By(anim_alpha)) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.at(50.0)
  t.frame(200.0, 200.0, now=50.0) |> ignore
  let na = t.nodes[a_view.val.unwrap().at]
  let nb = t.nodes[b_view.val.unwrap().at]
  assert_true(na.alpha_animating, msg="first alpha reader must see alpha_animating=true")
  assert_true(nb.alpha_animating, msg="second alpha reader hitting memo cache must also see alpha_animating=true")

  // Past end of drawn_while (200ms): at_moment fires, clock is no longer read, so alpha_animating must clear.
  t.frame(200.0, 200.0, now=250.0) |> ignore
  t.at(250.0)
  t.frame(200.0, 200.0, now=250.0) |> ignore
  assert_true(!t.nodes[a_view.val.unwrap().at].alpha_animating, msg="first alpha reader clears alpha_animating at rest")
  assert_true(!t.nodes[b_view.val.unwrap().at].alpha_animating, msg="second alpha reader clears alpha_animating at rest")
}
