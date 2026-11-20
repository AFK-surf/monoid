// A chat's mark coming while its row shows (chat_mark_node) fades in over @sf.dur_ms (140 ms Out)
// with constant scale (1.0, zero overshoot), while a mark already present on mount settles silently.

///|
test "chat_mark_node: silent on initial mount, pure fade-in over @sf.dur_ms with constant scale on tone change" {
  let tone = @signals.signal("done", same=fn(a, b) { a == b })
  let t = @ui.Tester::new(fn(_c) {  }, w=200.0, h=100.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(h) {
      h.width(Is(Some(100.0))).height(Is(Some(40.0))) |> ignore
      chat_mark_node(h, fn() { tone.get() })
    })
    |> ignore
  })
  t.draw()
  // Initial non-empty tone settles immediately at rest (alpha = 1.0, no motion).
  assert_true(t.at_rest(), msg="initial mark should settle silently")
  let dot_rects = fn() { t.drawn_rects().filter(fn(r) { r.2 > 0.0 && r.3 > 0.0 && r.2 < 20.0 && r.3 < 20.0 }) }
  match dot_rects() {
    [r] => {
      assert_true((r.2 - chat_mark_dot).abs() < 0.01 && (r.3 - chat_mark_dot).abs() < 0.01, msg="initial dot size=\{Repr(r)}")
      assert_eq(r.4 & 0xFFL, 0xFFL, msg="initial dot should be fully opaque")
    }
    other => fail("expected one initial dot rect, got \{Repr(other)}")
  }
  // Tone changes from "done" to "alert": pure fade-in over @sf.dur_ms, scale stays 1.0 (dot size constant at 8.0).
  tone.set("alert")
  t.draw()
  let start = t.time()
  let end = start + @sf.dur_ms
  let alphas : Array[Int64] = []
  while t.time() < end {
    let w = t.wanted_after()
    if w == @double.infinity {
      break
    }
    t.frame_at(if w <= t.time() { t.next_frame_time() } else { t.display_frame(w) })
    match dot_rects() {
      [r] => {
        // Scale must remain strictly 1.0 (no 1.3x overshoot, no shrink).
        assert_true((r.2 - chat_mark_dot).abs() < 0.01 && (r.3 - chat_mark_dot).abs() < 0.01, msg="dot scaled during fade: \{Repr(r)}")
        let a = r.4 & 0xFFL
        if alphas.is_empty() || alphas[alphas.length() - 1] != a {
          alphas.push(a)
        }
      }
      [] => ()
      other => fail("unexpected dot rects during fade: \{Repr(other)}")
    }
  }
  t.frame_at(t.display_frame(end))
  assert_true(t.at_rest(), msg="mark should rest after @sf.dur_ms")
  assert_true(alphas.length() >= 3, msg="expected monotonic fade steps, got \{Repr(alphas)}")
  for i in 1..<alphas.length() {
    assert_true(alphas[i] >= alphas[i - 1], msg="alpha should rise monotonically: \{Repr(alphas)}")
  }
  match dot_rects() {
    [r] => {
      assert_true((r.2 - chat_mark_dot).abs() < 0.01 && (r.3 - chat_mark_dot).abs() < 0.01, msg="final dot size=\{Repr(r)}")
      assert_eq(r.4 & 0xFFL, 0xFFL, msg="final dot should be fully opaque")
    }
    other => fail("expected one final dot rect, got \{Repr(other)}")
  }
}
