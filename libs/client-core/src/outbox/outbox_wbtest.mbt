// The outbox as a window's frames meet it: `wake` counted where mbui's `@ui.wake_frame` would be called, `take` called
// where its `@ui.on_frame_take` would, at a frame's start.

///|
/// A change of the test's: a typed value, handed over as it is.
#derive(Eq, Debug)
priv struct Patch {
  key : String
  rows : Array[Int]
}

///|
test "five changes between two frames ask for one frame, and it takes all five, the same objects" {
  let wakes = Ref(0)
  let outbox : FrameOutbox[Patch] = FrameOutbox::new(() => wakes.val += 1)
  let told = Array::makei(5, i => Patch::{ key: "chat/\{i}", rows: [i, i + 1] })
  for p in told {
    outbox.tell(p)
  }
  assert_eq(wakes.val, 1)
  assert_eq(outbox.waiting(), 5)
  let got = outbox.take()
  assert_eq(got, told)
  for i, p in got {
    assert_true(physical_equal(p, told[i]))
  }
  assert_eq(outbox.takes(), 1)
  assert_eq(outbox.waiting(), 0)
  // nothing told: nothing asked
  assert_eq(outbox.take(), [])
  assert_eq(wakes.val, 1)
}

///|
test "what is told while a frame takes asks for the next frame" {
  let wakes = Ref(0)
  let outbox : FrameOutbox[Int] = FrameOutbox::new(() => wakes.val += 1)
  outbox.tell(1)
  let first = outbox.take()
  assert_eq(first, [1])
  // (told while that frame works with what it took)
  outbox.tell(2)
  outbox.tell(3)
  assert_eq(wakes.val, 2)
  assert_eq(outbox.take(), [2, 3])
  assert_eq(outbox.wakes(), 2)
}

///|
test "a frame that takes some leaves the rest for the next, which it asks for" {
  let wakes = Ref(0)
  let outbox : FrameOutbox[Int] = FrameOutbox::new(() => wakes.val += 1)
  for i in 0..<7 {
    outbox.tell(i)
  }
  assert_eq(outbox.take(most=3), [0, 1, 2])
  assert_eq(wakes.val, 2)
  outbox.tell(7)
  assert_eq(wakes.val, 2)
  assert_eq(outbox.take(most=3), [3, 4, 5])
  assert_eq(wakes.val, 3)
  assert_eq(outbox.take(most=3), [6, 7])
  assert_eq(wakes.val, 3)
}
