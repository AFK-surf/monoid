// Reorder (`@headless.Reorder`, `@headless.reorder_apply`) and cross-container transfer (`@headless.Transfer`), under
// `window` (window_test.mbt) so zero-draw is enforced.

///|
test "reorder_apply: pure array reordering forward, backward, clamped, and out-of-range no-op" {
  let src = ["a", "b", "c", "d"]
  let fwd = @headless.reorder_apply(src, 0, 2)
  let bwd = @headless.reorder_apply(src, 3, 1)
  let clamped = @headless.reorder_apply(src, 0, 99)
  let same = @headless.reorder_apply(src, 1, 1)
  let invalid = @headless.reorder_apply(src, -1, 2)
  assert_eq(
    (src, fwd, bwd, clamped, same, invalid),
    (
      ["a", "b", "c", "d"],
      ["b", "c", "a", "d"],
      ["a", "d", "b", "c"],
      ["b", "c", "d", "a"],
      ["a", "b", "c", "d"],
      ["a", "b", "c", "d"],
    ),
  )
}

///|
test "Reorder: pointer drag with slop gating, target center tracking, scroll_speed, commit, and cancel" {
  let items = @signals.signal(["a", "b", "c"])
  let commits : Array[(String, Int, Int)] = []
  let r = @headless.Reorder::new(
    fn() { items.untracked() },
    fn(k, from, to) {
      commits.push((k, from, to))
      items.set(@headless.reorder_apply(items.untracked(), from, to))
    },
    axis=Vertical,
    slop=4.0,
  )
  let centers = [20.0, 60.0, 100.0]
  // Start drag at y=20.0; moving 2pt (< slop 4.0) keeps drag inactive
  r.start_drag("a", 20.0)
  r.move_drag(22.0, centers)
  let before_slop = (r.active(), r.is_dragging("a"), r.drop_index(), r.scroll_speed(10.0, 0.0, 120.0))
  // Move past slop to y=95.0 (nearest center 100.0 -> index 2)
  r.move_drag(95.0, centers)
  let active_draft = r.active()
  let dragging_a = r.is_dragging("a")
  let dragging_b = r.is_dragging("b")
  let drop_at = r.drop_index()
  let edge_up = r.scroll_speed(5.0, 0.0, 120.0, zone=30.0, max_speed=1.0)
  let edge_mid = r.scroll_speed(60.0, 0.0, 120.0, zone=30.0, max_speed=1.0)
  let edge_down = r.scroll_speed(115.0, 0.0, 120.0, zone=30.0, max_speed=1.0)
  r.commit()
  let after_commit = (items.untracked(), commits.copy(), r.active())
  // Cancel does not commit
  r.start_drag("c", 60.0)
  r.move_drag(20.0, centers)
  assert_true(r.active() is Some(_))
  r.cancel()
  assert_eq(
    (before_slop, active_draft, dragging_a, dragging_b, drop_at, edge_up < 0.0, edge_mid == 0.0, edge_down > 0.0),
    (
      (None, false, None, 0.0),
      Some({ key: "a", from_index: 0, to_index: 2, by_keyboard: false }),
      true,
      false,
      Some(2),
      true,
      true,
      true,
    ),
  )
  assert_eq(
    (after_commit, commits.length(), r.active()),
    ((["b", "c", "a"], [("a", 0, 2)], None), 1, None),
  )
}

///|
test "Reorder::item: keyboard Space grab, Arrow/Home/End move, Enter/Space commit, Escape cancel under window" {
  let items = @signals.signal(["一", "二", "三"])
  let commits : Array[(String, Int, Int)] = []
  let r = @headless.Reorder::new(
    fn() { items.untracked() },
    fn(k, from, to) {
      commits.push((k, from, to))
      items.set(@headless.reorder_apply(items.untracked(), from, to))
    },
    axis=Vertical,
  )
  let t = window(fn(root) {
    for name in ["一", "二", "三"] {
      let b = @headless.button(root, fn() { name }, fn(_) {  }, fn(v, _) {
        v.width(Is(Some(100.0))).height(Is(Some(28.0))) |> ignore
      })
      r.item(b, name)
    }
  })
  // Focus "一", Space grabs it, Down -> 1, End -> 2, Enter commits
  t.act(Button, Focus, label="一")
  t.key(@ui.key_of_char(' '))
  let grabbed = r.active()
  t.key(@ui.key_code_down)
  let at_1 = r.drop_index()
  t.key(@ui.key_code_end)
  let at_end = r.drop_index()
  t.key(@ui.key_code_home)
  let at_home = r.drop_index()
  t.key(@ui.key_code_down)
  t.key(@ui.key_code_down)
  t.enter()
  let after_commit = (items.untracked(), commits.copy(), r.active())
  // Grab "二", move Up, press Escape -> cancelled without commit
  t.act(Button, Focus, label="二")
  t.key(@ui.key_of_char(' '))
  t.key(@ui.key_code_up)
  t.key(@ui.key_escape)
  assert_eq(
    (grabbed, at_1, at_end, at_home, after_commit, commits.length(), r.active()),
    (
      Some({ key: "一", from_index: 0, to_index: 0, by_keyboard: true }),
      Some(1),
      Some(2),
      Some(0),
      (["二", "三", "一"], [("一", 0, 2)], None),
      1,
      None,
    ),
  )
}

///|
test "Transfer: programmatic and keyboard cross-container moves (including RTL and empty column) under window" {
  let cols = ["todo", "doing", "done"]
  let todo = @signals.signal(["t1", "t2"])
  let doing = @signals.signal(["d1"])
  let done : @signals.Signal[Array[String]] = @signals.signal([])
  let transfers : Array[(String, String, Int, String, Int)] = []
  let items_of = fn(c : String) -> Array[String] {
    if c == "todo" {
      todo.untracked()
    } else if c == "doing" {
      doing.untracked()
    } else {
      done.untracked()
    }
  }
  let tr = @headless.Transfer::new(
    fn() { cols },
    items_of,
    fn(k, fc, fi, tc, ti) { transfers.push((k, fc, fi, tc, ti)) },
  )
  // Programmatic API: move t1 from todo[0] to doing[1]
  tr.start("todo", "t1")
  tr.step_container(1)
  tr.step_item(1)
  let prog_draft = tr.active()
  tr.commit()
  let prog_res = (transfers.copy(), tr.active())
  // Keyboard API under window (LTR and RTL)
  let t = window(fn(root) {
    let b1 = @headless.button(root, fn() { "t1" }, fn(_) {  }, fn(v, _) {
      v.width(Is(Some(80.0))).height(Is(Some(28.0))) |> ignore
    })
    tr.item(b1, "todo", "t1")
    let b2 = @headless.button(root, fn() { "d1" }, fn(_) {  }, fn(v, _) {
      v.width(Is(Some(80.0))).height(Is(Some(28.0))) |> ignore
    })
    tr.item(b2, "doing", "d1", rtl=true)
  })
  // LTR: focus t1, Space grab, Right -> doing, Right -> done (empty, index clamped to 0), Space commits
  t.act(Button, Focus, label="t1")
  t.key(@ui.key_of_char(' '))
  t.key(@ui.key_code_right)
  t.key(@ui.key_code_right)
  let kb_draft = tr.active()
  t.key(@ui.key_of_char(' '))
  // RTL: focus d1 in doing, Space grab, Left moves forward to done, Escape cancels
  t.act(Button, Focus, label="d1")
  t.key(@ui.key_of_char(' '))
  t.key(@ui.key_code_left)
  let rtl_draft = tr.active()
  t.key(@ui.key_escape)
  assert_eq(
    (prog_draft, prog_res, kb_draft, rtl_draft, transfers.copy(), tr.active()),
    (
      Some({
        key: "t1",
        from_container: "todo",
        from_index: 0,
        to_container: "doing",
        to_index: 1,
        by_keyboard: false,
      }),
      ([("t1", "todo", 0, "doing", 1)], None),
      Some({
        key: "t1",
        from_container: "todo",
        from_index: 0,
        to_container: "done",
        to_index: 0,
        by_keyboard: true,
      }),
      Some({
        key: "d1",
        from_container: "doing",
        from_index: 0,
        to_container: "done",
        to_index: 0,
        by_keyboard: true,
      }),
      [("t1", "todo", 0, "doing", 1), ("t1", "todo", 0, "done", 0)],
      None,
    ),
  )
}
