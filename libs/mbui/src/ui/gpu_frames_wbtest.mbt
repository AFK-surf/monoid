// What the drawing side did with the frames (frame_watch.mbt GpuFrames): each frame's GPU time counted past the
// budgets of 120 and 60 frames a second and a hang's, the frames the host never drew counted by what its count grew.

///|
test "the frames drawn counted past each budget, those never drawn by what the host's count grew" {
  let _ = gpu_frames_take()
  gpu_dropped_seen.val = 0
  // (a host that knows no GPU time: none timed)
  gpu_frames_count(-1.0, 0)
  // 120's budget kept, 120's gone past, 60's gone past, a hang's
  gpu_frames_count(8.0, 0)
  gpu_frames_count(9.0, 0)
  gpu_frames_count(17.0, 2)
  gpu_frames_count(24.0, 2)
  gpu_frames_count(3.0, 5)
  let f = gpu_frames_take()
  assert_eq(f, {
    timed: 5,
    over_120: 3,
    over_60: 2,
    over_hang: 1,
    worst_ms: 24.0,
    dropped: 5,
  })
  assert_eq(
    f.said(),
    "GPU frames=5 over_8ms=3 over_16ms=2 over_24ms=1 worst=24 dropped=5",
  )
  // (taken: none since; the host's count as it was, nothing more dropped)
  gpu_frames_count(4.0, 5)
  assert_eq(gpu_frames_take(), {
    timed: 1,
    over_120: 0,
    over_60: 0,
    over_hang: 0,
    worst_ms: 4.0,
    dropped: 0,
  })
}

