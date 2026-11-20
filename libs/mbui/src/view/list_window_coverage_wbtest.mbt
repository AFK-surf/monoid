// Cover what is drawn after a layout asked before its slots can be made, and after a scroll told during its layout.

///|
fn coverage_list(
  s : Scroll,
  clock : Ref[Double],
  reused : Bool,
  keys? : () -> Array[Int],
) -> Tree {
  let fixed = Array::makei(240, fn(k) { k })
  let keys = keys.unwrap_or(fn() { fixed })
  let row = fn(v : View, k : () -> Int) {
    v.box(fn(b) {
      b.height(By(fn() { Some(heights_several(k())) })).words(By(fn() { "row \{k()}" })) |> ignore
    })
    |> ignore
  }
  let t = Tree::new(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
      if reused {
        b.scrolls_window(s, keys, est=30.0, at_once=true, reused=fn(_) { Some(0) }, make_reused=row, fn(_, _) {
          @halt.saying("every row can be reused")
        })
        |> ignore
      } else {
        b.scrolls_window(s, keys, est=30.0, at_once=true, fn(v, k) { row(v, fn() { k }) }) |> ignore
      }
    })
    |> ignore
  }, time=fn() { clock.val })
  t.frame(300.0, 200.0) |> ignore
  t
}

///|
test "a batched layout across unmeasured list rows covers the viewport on every frame down and back" {
  let faults = []
  for fps in [60.0, 120.0, 24.0, 7.0] {
    for reused in [false, true] {
      let clock = Ref(0.0)
      let s = Scroll::list()
      let t = coverage_list(s, clock, reused)
      let host = s.host.unwrap()
      for y in [2055.0, 2125.0, 2295.0, 2125.0, 1925.0, 1705.0] {
        clock.val += 1000.0 / fps
        @signals.start_batch()
        s.put(y)
        t.layout_marked_at(host.at)
        t.laid_now() |> ignore
        @signals.end_batch()
        t.frame(300.0, 200.0) |> ignore
        for fault in heights_unjoined(heights_rows(t), heights_several, 0.0) {
          if faults.length() < 12 {
            faults.push("\{fps} fps, reused \{reused}, scroll \{y}: \{fault}")
          }
        }
        assert_true((s.where_at(clock.val) - y).abs() < 100.0, msg="scroll must reach its new window")
      }
    }
  }
  assert_eq(faults, [])
}

///|
test "a scroll told in the last reach measurement fills the new list viewport in that frame" {
  let clock = Ref(0.0)
  let s = Scroll::list()
  let t = coverage_list(s, clock, false)
  let host = s.host.unwrap()
  let fill = s.fill
  let moved_in = Ref(-1)
  s.fill = fn(w, h, performing) {
    fill(w, h, performing)
    if performing && moved_in.val < 0 {
      let put = s.fill_put
      s.fill_put = fn() {
        put()
        moved_in.val = t.rooming
        s.put(2055.0)
      }
    }
  }
  clock.val = 16.0
  t.layout_marked_at(host.at)
  t.frame(300.0, 200.0) |> ignore
  assert_eq(moved_in.val, host.at)
  assert_eq(heights_unjoined(heights_rows(t), heights_several, 0.0), [])
  assert_true(heights_rows(t)[0].0 > 50)
}

///|
test "a new row told in the last reach measurement replaces a drawn row of the same height in that frame" {
  let clock = Ref(0.0)
  let s = Scroll::list()
  let keys = @signals.signal(Array::makei(240, fn(k) { k }))
  let t = coverage_list(s, clock, true, keys=fn() { keys.get() })
  let host = s.host.unwrap()
  assert_eq(heights_rows(t)[2].0, 2)
  let fill = s.fill
  let old = keys.untracked()
  let next = old.copy()
  next[2] = 242
  s.fill = fn(w, h, performing) {
    fill(w, h, performing)
    if performing && physical_equal(keys.untracked(), old) {
      let put = s.fill_put
      s.fill_put = fn() {
        put()
        keys.set(next)
      }
    }
  }
  clock.val = 16.0
  t.layout_marked_at(host.at)
  t.frame(300.0, 200.0) |> ignore
  assert_eq(heights_rows(t)[2].0, 242)
}

///|
test "an alone slot marked again by another slot's measurement is measured again in the same layout" {
  let slots = []
  let children = []
  let t = Tree::new(fn(root) {
    for _ in 0..<2 {
      root.box(fn(slot) {
        slots.push(slot.at)
        slot.height(Is(Some(30.0))).lays_out_alone() |> ignore
        slot.box(fn(child) {
          children.push(child.at)
          child.height(Is(Some(10.0))).words(Is("row")) |> ignore
        })
        |> ignore
      })
      |> ignore
    }
  }, time=fn() { 0.0 })
  t.frame(300.0, 200.0) |> ignore
  let calls = []
  t.alone_asks[slots[0]] = fn() {
    calls.push(0)
    false
  }
  t.alone_asks[slots[1]] = fn() {
    calls.push(1)
    t.layout_marked_at(children[0])
    false
  }
  t.layout_marked_at(children[0])
  t.layout_marked_at(children[1])
  t.frame(300.0, 200.0) |> ignore
  assert_eq(calls, [0, 1, 0])
}
