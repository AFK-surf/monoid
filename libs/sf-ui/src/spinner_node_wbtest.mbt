// The spinner as a node of the window's tree (spinner_node): its ring and arc, turned as the clock goes; turning,
// nothing of it made again, each frame painted alone or of its looks alone, nothing built.

///|
/// The spinner as a node, 14 across.
fn spinner_tester() -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=200.0, h=100.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.row(Is(true)).lines_up(Is(Some(Start))) |> ignore
    spinner_node(root) |> ignore
  })
  t.draw()
  t
}

///|
/// The pieces of lines drawn by spinner_node (place, size, ends, colour, how far it is turned and about where).
fn spinner_drawn(t : @ui.Tester) -> Array[Array[Double]] {
  let out = []
  for i in t.drawn_instances() {
    if i[5] != 10.0 {
      continue
    }
    out.push([i[0], i[1], i[2], i[3], i[4], i[8], i[9], i[10], i[11], i[12], i[13], i[14], i[15], i[32], i[33], i[34]])
  }
  out
}

///|
test "the spinner as a node turns as the clock advances; turning, nothing of it made again" {
  let t = spinner_tester()
  let new0 = spinner_drawn(t)
  let made = @ui.view_painted().made
  t.frame_at(t.time() + 300.0)
  let new1 = spinner_drawn(t)
  let about = new1.map(fn(p) { [p[14], p[15]] })
  assert_eq(
    (
      new0.length() > 0,
      new1.length() == new0.length(),
      new1 != new0,
      about.iter().all(fn(p) { (p[0] - 7.0).abs() > 0.01 }),
      @ui.view_painted().made - made,
    ),
    (true, true, true, true, 0),
    msg="node \{Repr(about[:1])}",
  )
}

///|
/// How long a page with spinners is watched turning (a second at the display's rate), from a turn after it is first
/// drawn (the frame after its first lays it out once more, as any page's does).
let spinning_watched_ms : Double = 1000.0

///|
/// A page that waits: words and the spinner as a node of the window's tree. What only turns as the clock goes is drawn
/// by the frames' looks or paint alone: the page's build reads no time.
fn spinning_page() -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=200.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.row(Is(true)).lines_up(Is(Some(Start))) |> ignore
    words_node(root, fn() { "正在读取会话" }, fn() { wait_words }) |> ignore
    spinner_node(root) |> ignore
  })
  t.draw()
  t
}

///|
test "a page whose spinners turn: each frame of their turning is painted alone or of its looks alone, nothing built" {
  let t = spinning_page()
  t.run_for(spinner_turn_ms)
  let new0 = spinner_drawn(t)
  let until = t.time() + spinning_watched_ms
  let built : Array[String] = []
  let mut frames = 0
  while t.time() < until {
    let w = t.wanted_after()
    if w == @double.infinity {
      break
    }
    t.frame_at(if w <= t.time() { t.next_frame_time() } else { t.display_frame(w) })
    frames += 1
    let perf = t.frame_perf()
    if t.built_why() != "" || !(perf.looks || perf.painted) {
      built.push("\{t.time()}: \{t.built_why()} \{Repr(perf)}")
    }
  }
  let new1 = spinner_drawn(t)
  // (it turns: a frame asked for each of the display's, each drawing it turned on)
  assert_eq(
    (frames >= 55, new1 != new0),
    (true, true),
    msg="\{frames} frames; node \{new0.length()} \{Repr(new0[:1])} -> \{Repr(new1[:1])}; \{t.time()}; built \{Repr(built[:2])}",
  )
  assert_eq(built, [], msg="\{built.length()} of \{frames} frames built")
}
