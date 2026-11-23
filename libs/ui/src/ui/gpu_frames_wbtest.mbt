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

///|
test "gpu_frames_count tracks per-page stats and deduplicates repeated asynchronous last_gpu >= 24ms" {
  journal_reset()
  gpu_dropped_seen.val = 0
  journal_shows("Home")
  gpu_frames_count(10.0, 0)
  assert_eq(gpu_frame_consume(), (10.0, 0, false))
  // First 28.4ms GPU frame triggers slow flag
  gpu_frames_count(28.4, 0)
  assert_eq(gpu_frame_consume(), (28.4, 0, true))
  // Repeated identical 28.4ms value from async host does not re-trigger
  gpu_frames_count(28.4, 0)
  assert_eq(gpu_frame_consume(), (28.4, 0, false))
  // A different >= 24ms value triggers again
  gpu_frames_count(31.2, 0)
  assert_eq(gpu_frame_consume(), (31.2, 0, true))
  // Dropping back below 24ms resets dedup so a later 31.2ms triggers again
  journal_shows("Chat")
  gpu_frames_count(6.0, 0)
  assert_eq(gpu_frame_consume(), (6.0, 0, false))
  gpu_frames_count(31.2, 0)
  assert_eq(gpu_frame_consume(), (31.2, 0, true))
  // Dropped frame delta triggers even if gms is unchanged
  gpu_frames_count(31.2, 2)
  assert_eq(gpu_frame_consume(), (31.2, 2, true))
  let by_page = gpu_by_page_take()
  assert_eq(by_page, [
    ("Home", 4, 4, 3, 3, 31.2, 0),
    ("Chat", 3, 2, 2, 2, 31.2, 2),
  ])
  let _ = gpu_frames_take()
}

