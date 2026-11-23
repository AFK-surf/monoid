// What a core on a runtime of its own hands over to the frames (on_frame_take, wake_frame): said any number of times
// between two frames, it asks for one frame, which takes it once as it begins, before it decides what it does, so
// what the take sets is drawn by that frame; what the take reads is not the frame's to follow; a take that says it
// again is taken by the frame after, and then the app is at rest.

///|
/// How long a Tester runs before the core says it has something.
let frame_take_before_ms : Double = 100.0

///|
/// A Tester of the window's tree drawing `label`, at rest; the frames drawn from now on counted into `frames`, with
/// the words each drew.
fn frame_take_tester(
  label : @signals.Signal[String],
  frames : Array[String],
) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=200.0, h=200.0)
  set_view_app(fn(root) {
    root.box(fn(b) { b.words(By(fn() { label.get() })) |> ignore }) |> ignore
  })
  t.draw()
  t.check_looks(false)
  t.run_for(frame_take_before_ms)
  t.each_frame(
    Some(fn() { frames.push(t.words().map(fn(w) { w.0 }).join(" ")) }),
  )
  t
}

///|
test "said three times between two frames: one frame asked for, which takes once and draws what it set" {
  let label : @signals.Signal[String] = @signals.signal("none")
  // (what the core's own runtime has come to, outside any signal: read by the take alone)
  let core = Ref(0)
  // (read by the take: not the frame's to follow)
  let read : @signals.Signal[Int] = @signals.signal(0)
  let takes = Ref(0)
  on_frame_take(fn() {
    takes.val += 1
    read.get() |> ignore
    label.set("n=\{core.val}")
  })
  let frames : Array[String] = []
  let t = frame_take_tester(label, frames)
  assert_true(t.at_rest(), msg=t.rest_why())
  for _ in 0..<3 {
    core.val += 1
    wake_frame()
  }
  assert_eq(takes.val, 0)
  assert_false(t.at_rest())
  t.frames_owed()
  t.each_frame(None)
  assert_eq(takes.val, 1)
  // (the frame that took it drew it: no frame before it, none after)
  assert_eq(frames, ["n=3"])
  assert_true(t.at_rest(), msg=t.rest_why())
  // (what the take read changes: no frame for it, the take not run)
  read.set(1)
  assert_true(t.at_rest(), msg=t.rest_why())
  t.frame()
  assert_eq(t.built_why(), "")
  assert_eq(takes.val, 1)
}

///|
test "a take that says it again is taken by the frame after, and then it rests" {
  let label : @signals.Signal[String] = @signals.signal("none")
  let left = Ref(1)
  let takes = Ref(0)
  on_frame_take(fn() {
    takes.val += 1
    label.set("take \{takes.val}")
    // (more came while it was handed over: the next frame's)
    if left.val > 0 {
      left.val -= 1
      wake_frame()
    }
  })
  let frames : Array[String] = []
  let t = frame_take_tester(label, frames)
  wake_frame()
  t.frames_owed()
  t.each_frame(None)
  assert_eq(takes.val, 2)
  assert_eq(frames, ["take 1", "take 2"])
  assert_true(t.at_rest(), msg=t.rest_why())
}
