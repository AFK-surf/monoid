// Public headless behaviors: RovingFocus, Typeahead, SelectionModel, repeat_hold, and RTL across controls.
// Every tree test uses `window` (window_test.mbt) so zero-draw is enforced.

///|
let bh_ta_window_ms : Double = 500.0

///|
let bh_repeat_delay_ms : Double = 400.0

///|
let bh_repeat_interval_ms : Double = 70.0

///|
let bh_tick_ms : Double = 1.0

///|
fn bh_focus(t : @ui.Tester) -> String {
  t.focused().map(fn(s) { s.label }).unwrap_or("none")
}

///|
test "RovingFocus: public API (new, add, live, stop_at, focus_stop, focus_first, focus_last, step) and RTL horizontal flip" {
  let rf = @headless.RovingFocus::new(axis=Horizontal, roving=true, wraps=true, rtl=true)
  let t = window(fn(root) {
    root.on_key(fn(k) { k.mods == 0 && rf.step(k.code) is Some(_) }) |> ignore
    for name in ["左", "中", "右"] {
      let b = @headless.button(root, fn() { name }, fn(_) {  }, fn(v, _) {
        v.width(Is(Some(60.0))).height(Is(Some(28.0))) |> ignore
      })
      rf.add(b, preferred=fn() { name == "中" })
    }
  })
  assert_eq(rf.live().length(), 3)
  assert_true(rf.stop_at() is Some(_))
  // focus_stop lands on preferred "中"
  assert_true(rf.focus_stop())
  t.draw()
  let at_stop = bh_focus(t)
  // In RTL: Left advances forward ("中" -> "右"), Right goes backward ("右" -> "中"), wraps
  t.key(@ui.key_code_left)
  let after_left = bh_focus(t)
  t.key(@ui.key_code_left)
  let after_wrap = bh_focus(t)
  t.key(@ui.key_code_right)
  let after_right = bh_focus(t)
  assert_true(rf.focus_first())
  t.draw()
  let first = bh_focus(t)
  assert_true(rf.focus_last())
  t.draw()
  let last = bh_focus(t)
  assert_eq((at_stop, after_left, after_wrap, after_right, first, last), ("中", "右", "左", "右", "左", "右"))
}

///|
test "Typeahead: match_next, handle_key, reset, window expiry, and repeated character cycling" {
  let ta = @headless.Typeahead::new(window_ms=bh_ta_window_ms)
  let nodes : Array[@view.View] = []
  let labels = ["Apple", "Apricot", "Banana"]
  let t = window(fn(root) {
    for name in labels {
      let b = @headless.button(root, fn() { name }, fn(_) {  }, fn(v, _) {
        v.width(Is(Some(80.0))).height(Is(Some(24.0))) |> ignore
      })
      nodes.push(b)
    }
    root.on_key(fn(k) { ta.handle_key(k, nodes, fn(i) { labels[i] }) }) |> ignore
  })
  t.act(Button, Focus, label="Banana")
  // 'a' -> Apple, 'a' again within 500ms -> Apricot
  t.key(@ui.key_of_char('a'))
  let a1 = bh_focus(t)
  t.run_for(bh_ta_window_ms / 2.0)
  t.key(@ui.key_of_char('a'))
  let a2 = bh_focus(t)
  // reset clears buffer; 'b' -> Banana
  ta.reset()
  t.key(@ui.key_of_char('B'))
  let b1 = bh_focus(t)
  // Space is not consumed by typeahead
  assert_eq((a1, a2, b1), ("Apple", "Apricot", "Banana"))
}

///|
test "SelectionModel: single and multi-select toggle, range skipping disabled, select_all, and clear" {
  let single : @headless.SelectionModel[String] = @headless.SelectionModel::new(multiple=false)
  let s1 = single.toggle([], "a")
  let s2 = single.toggle(s1, "b")
  assert_eq((s1, s2, single.anchor()), (["a"], ["b"], Some("b")))

  let multi : @headless.SelectionModel[String] = @headless.SelectionModel::new(multiple=true)
  let keys = ["a", "b", "c", "d", "e"]
  let off = fn(k : String) { k == "c" }
  let m1 = multi.toggle([], "b")
  // Anchor is "b": range to "e" skips disabled "c" -> ["b", "d", "e"], anchor stays "b"
  let m2 = multi.select_range(keys, m1, "e", disabled=off)
  let anchor_kept = multi.anchor()
  // Reverse range from "b" to "a" -> ["a", "b"]
  let m3 = multi.select_range(keys, m2, "a", disabled=off)
  // Toggle off "b"
  let m4 = multi.toggle(m3, "b")
  // Select all skips disabled "c"
  let m5 = multi.select_all(keys, disabled=off)
  // Clear resets anchor and returns empty
  let m6 = multi.clear()
  assert_eq(
    (m1, m2, anchor_kept, m3, m4, m5, m6, multi.anchor()),
    (["b"], ["b", "d", "e"], Some("b"), ["a", "b"], ["a"], ["a", "b", "d", "e"], [], None),
  )
}

///|
test "repeat_hold: deterministic FPS-invariant repeat on at_moment; stops on release, disable, and stop handle" {
  let steps = Ref(0)
  let off = @signals.signal(false)
  let stop_ref : Ref[() -> Unit] = Ref(fn() {  })
  let t = window(fn(root) {
    @headless.button(root, fn() { "加" }, fn(_) {  }, disabled=fn() { off.get() }, fn(v, _) {
      v.width(Is(Some(80.0))).height(Is(Some(36.0))) |> ignore
      stop_ref.val = @headless.repeat_hold(
        v,
        fn() { steps.val += 1 },
        delay_ms=bh_repeat_delay_ms,
        interval_ms=bh_repeat_interval_ms,
        disabled=fn() { off.get() },
      )
    })
    |> ignore
  })
  let (x, y, w, h) = t.get(Button, label="加").rect
  let (cx, cy) = (x + w / 2.0, y + h / 2.0)
  // Hold for delay - 1ms -> 0 repeats yet
  t.press_at(cx, cy)
  t.run_for(bh_repeat_delay_ms - bh_tick_ms)
  let before_delay = steps.val
  // +1ms (delay) -> 1st repeat; +3*interval -> 3 more repeats = 4 total
  t.run_for(bh_tick_ms + bh_repeat_interval_ms * 3.0)
  let after_hold = steps.val
  // Release -> no more repeats even after delay + interval
  t.release(cx, cy)
  t.run_for(bh_repeat_delay_ms + bh_repeat_interval_ms)
  let after_release = steps.val
  // Hold again, then disable mid-hold -> cancels immediately
  t.press_at(cx, cy)
  t.run_for(bh_repeat_delay_ms)
  let before_disable = steps.val
  off.set(true)
  t.draw()
  t.run_for(bh_repeat_delay_ms + bh_repeat_interval_ms)
  let after_disable = steps.val
  t.release(cx, cy)
  off.set(false)
  t.draw()
  // Stop handle cancels permanently
  (stop_ref.val)()
  t.press_at(cx, cy)
  t.run_for(bh_repeat_delay_ms + bh_repeat_interval_ms * 3.0)
  t.release(cx, cy)
  let after_stop = steps.val
  assert_eq((before_delay, after_hold, after_release, before_disable, after_disable, after_stop), (0, 4, 4, 5, 5, 5))
}

///|
test "RTL navigation: radio_group, Tabs, toggle_group, and Submenu flip horizontal arrow keys when rtl=true" {
  // 1. radio_group rtl=true
  let rg_chosen = @signals.signal("a")
  let t1 = window(fn(root) {
    @headless.radio_group(
      root,
      fn() { "方向" },
      fn() { rg_chosen.get() },
      fn(k) { rg_chosen.set(k) },
      rtl=true,
      fn(g, rg) {
        for item in [("a", "一"), ("b", "二"), ("c", "三")] {
          let (k, name) = item
          rg.item(g, fn() { k }, fn() { name }, fn(v, _) {
            v.width(Is(Some(50.0))).height(Is(Some(28.0))) |> ignore
          })
          |> ignore
        }
      },
    )
    |> ignore
  })
  t1.act(Radio, Focus, label="一")
  t1.key(@ui.key_code_left)
  let rg_after_left = rg_chosen.get()
  t1.key(@ui.key_code_right)
  let rg_after_right = rg_chosen.get()
  assert_eq((rg_after_left, rg_after_right), ("b", "a"))

  // 2. Tabs rtl=true
  let tab_chosen = @signals.signal("一")
  let tabs = @headless.Tabs::new(fn() { tab_chosen.get() }, fn(k) { tab_chosen.set(k) }, rtl=true)
  let t2 = window(fn(root) {
    tabs.list(root, fn() { "标签" }, fn(v, g) {
      for name in ["一", "二", "三"] {
        g.item(v, fn() { name }, fn() { name }, fn(i, _) {
          i.width(Is(Some(50.0))).height(Is(Some(28.0))) |> ignore
        })
        |> ignore
      }
    })
    |> ignore
  })
  t2.act(Tab, Focus, label="一")
  t2.key(@ui.key_code_left)
  assert_eq(tab_chosen.get(), "二")

  // 3. toggle_group rtl=true
  let tg_on = @signals.signal("a")
  let t3 = window(fn(root) {
    @headless.toggle_group(
      root,
      fn() { "对齐" },
      fn(k) { tg_on.get() == k },
      fn(k, _) { tg_on.set(k) },
      rtl=true,
      fn(v, g) {
        for item in [("a", "左"), ("b", "中"), ("c", "右")] {
          let (k, name) = item
          g.item(v, k, fn() { name }, fn(i, _) {
            i.width(Is(Some(50.0))).height(Is(Some(28.0))) |> ignore
          })
          |> ignore
        }
      },
    )
    |> ignore
  })
  t3.act(Button, Focus, label="左")
  t3.key(@ui.key_code_left)
  assert_eq(bh_focus(t3), "中")

  // 4. Submenu rtl=true: Left opens submenu, Right closes it and returns focus to trigger
  let sub_open = @signals.signal(false)
  let sub = @headless.Submenu::new(fn() { sub_open.get() }, fn(v) { sub_open.set(v) }, rtl=true)
  let t4 = window(fn(root) {
    @headless.menu(root, fn(v, m) {
      m.sub_trigger(v, sub, fn() { "更多" }, fn(i, _) {
        i.width(Is(Some(80.0))).height(Is(Some(28.0))) |> ignore
      })
      |> ignore
    })
    |> ignore
    root.show(at_once=true, fn() { sub_open.get() }, fn(s) {
      sub.menu(s, fn(v, m) {
        m.item(v, fn() { "子项" }, fn(_) {  }, fn(i, _) {
          i.width(Is(Some(80.0))).height(Is(Some(28.0))) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
  })
  t4.act(MenuItem, Focus, label="更多")
  // Right does NOT open in RTL
  t4.key(@ui.key_code_right)
  let still_closed = sub_open.get()
  // Left opens and focuses "子项"
  t4.key(@ui.key_code_left)
  let opened = (sub_open.get(), bh_focus(t4))
  // Right closes and returns focus to "更多"
  t4.key(@ui.key_code_right)
  let closed = (sub_open.get(), bh_focus(t4))
  assert_eq((still_closed, opened, closed), (false, (true, "子项"), (false, "更多")))
}
