///|
/// Tests for PR-B1 `Nav` per-kind `kept_left` quotas (`kept_left_most`, `kept_left_total`)
/// and `Tester::subtree_timeline_count` / `Tester::subtree_timeline_bys`.

///|
test "Nav kept_left per-kind quota evicts within kind without clobbering other kinds and respects total cap" {
  let nav : Nav[String] = Nav::new("root")
  nav.set_kept_left_limits(
    most_of=fn(k) {
      if k == "chat" {
        2
      } else if k == "setting" {
        2
      } else {
        0
      }
    },
    total=4,
  )
  let t = Tester::tree(
    fn(v) {
      nav_tree_view(
        v,
        nav,
        fn(p) {
          if p.has_prefix("c:") {
            "chat"
          } else if p.has_prefix("s:") {
            "setting"
          } else {
            "other"
          }
        },
        fn(pv, page, _, _, _) {
          pv.height(Is(Some(30.0))).words(By(fn() { page() })) |> ignore
        },
        keeps_left=fn(p) { if p == "root" { None } else { Some(p) } },
      )
      |> ignore
    },
    w=390.0,
    h=600.0,
  )
  t.frame()
  let push_and_pop = fn(name : String) -> Int {
    nav.push(name)
    t.run_for(move_most_ms)
    let serial = nav.pages.last().unwrap().serial
    nav.pop() |> ignore
    t.run_for(move_most_ms)
    serial
  }
  let c1 = push_and_pop("c:1")
  let s1 = push_and_pop("s:1")
  let c2 = push_and_pop("c:2")
  let s2 = push_and_pop("s:2")
  assert_true(nav.is_kept_left(c1))
  assert_true(nav.is_kept_left(c2))
  assert_true(nav.is_kept_left(s1))
  assert_true(nav.is_kept_left(s2))

  // Parking c:3 hits chat cap (2) -> evicts c:1, keeping both s:1 and s:2 intact!
  let c3 = push_and_pop("c:3")
  assert_false(nav.is_kept_left(c1), msg="oldest chat c:1 evicted by chat per-kind cap")
  assert_true(nav.is_kept_left(c2))
  assert_true(nav.is_kept_left(c3))
  assert_true(nav.is_kept_left(s1), msg="setting s:1 unaffected by chat eviction")
  assert_true(nav.is_kept_left(s2), msg="setting s:2 unaffected by chat eviction")

  // Parking a kind with cap 0 ("other") is never kept.
  let o1 = push_and_pop("o:1")
  assert_false(nav.is_kept_left(o1), msg="kind with cap 0 is not parked")
  assert_true(nav.is_kept_left(s1) && nav.is_kept_left(s2) && nav.is_kept_left(c2) && nav.is_kept_left(c3))

  // Lowering a kind's cap to 0 and leaving a same-key page removes the stale parked entry instead of leaking it.
  nav.set_kept_left_limits(most_of=fn(k) { if k == "chat" { 0 } else { 2 } }, total=4)
  nav.push("c:2")
  t.run_for(move_most_ms)
  let c2_re = nav.pages.last().unwrap().serial
  nav.pop() |> ignore
  t.run_for(move_most_ms)
  assert_false(nav.is_kept_left(c2_re), msg="cap 0 refuses re-parking and drops any stale same-key entry")
}

///|
test "Tester::subtree_timeline_count reports active later=true timers and drops to 0 when page is parked" {
  let nav : Nav[String] = Nav::new("root")
  let page_view : Ref[@view.View?] = Ref(None)
  let ticks = Ref(0)
  let poll_ms = 100.0
  let t = Tester::tree(
    fn(v) {
      nav_tree_view(
        v,
        nav,
        fn(p) { if p == "poll" { "poll" } else { "root" } },
        fn(pv, page, _, _, _) {
          let p = @signals.untracked(page)
          if p == "poll" {
            page_view.val = Some(pv)
            pv.while_active_every(poll_ms, fn() { ticks.val += 1 }, later=true) |> ignore
          }
          pv.height(Is(Some(30.0))).words(By(fn() { page() })) |> ignore
        },
        keeps_left=fn(p) { if p == "poll" { Some(p) } else { None } },
      )
      |> ignore
    },
    w=390.0,
    h=600.0,
  )
  t.frame()
  nav.push("poll")
  t.run_for(move_most_ms)
  let pv = page_view.val.unwrap()
  assert_eq(t.subtree_timeline_count(pv), 1, msg="active polling page owns 1 later=true timeline entry")
  assert_true(t.subtree_timeline_bys(pv).length() == 1)

  // Pop to park `poll` in `kept_left`: timeline count must drop to 0 and stay 0 across ticks!
  nav.pop() |> ignore
  t.run_for(move_most_ms)
  let ticks_at_park = ticks.val
  assert_eq(t.subtree_timeline_count(pv), 0, msg="parked page owns 0 timeline entries (including later=true)")
  t.run_for(5.0 * poll_ms)
  assert_eq(ticks.val, ticks_at_park, msg="0 ticks while parked")
}
