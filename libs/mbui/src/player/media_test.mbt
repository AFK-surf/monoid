// A player's ways (media.mbt) over the fake host (every view there ready, 10 s long, 640 × 360, paused), told as a
// player's nodes tell it: jumped on past its end, the speed stepped, dragged through its time (paused and sent along
// with the finger, its seeks one after another until let go), its decoder and a frame asked of it waited for so long.

///|
/// What is played in these: a video read by nothing (the fake host answers for it).
fn video(name : String, mime : String) -> @player.MediaTrack {
  { name, mime, audio: false, read: fn(_, _, _) { fn() {  } }, direct: "" }
}

///|
test "a player: jumped on goes there at once (to its end); the speed steps; dragged through its time it seeks as it goes" {
  let m = @player.Media::new()
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=844.0)
  m.open(video("a.mp4", "video/mp4"))
  t.draw()
  assert_true(m.take_ready())
  assert_true(m.started())
  // 15 s on (the fake is 10 s long: to its end), about there at once (the nearest key frame)
  m.seek_by(m.nudge_ms())
  assert_true(t.views().iter().any(fn(s) { s.has_prefix("control") && s.contains(" 11 10000") }))
  // the speed after 1×
  m.step_speed()
  assert_eq(m.speed(), 1.25)
  // dragged to the middle: paused, its seeks one after another, near key frames as it goes; let go, exact frame before scrub ends
  let told = fn(said : String) { t.views().iter().any(fn(s) { s.has_prefix("control") && s.contains(said) }) }
  m.scrub_to(5000.0)
  assert_eq(m.scrubbing(), Some(5000.0))
  assert_true(told(" 2 0"))
  assert_true(told(" 9 1"))
  assert_true(told(" 11 5000"))
  assert_false(told(" 3 5000"))
  m.scrub_done()
  t.draw()
  assert_true(m.scrubbing() is None)
  assert_true(told(" 3 5000"))
  assert_true(told(" 9 0"))
  let log = t.views()
  let exact_idx = log.search_by(fn(s) { s.has_prefix("control") && s.contains(" 3 5000") }).unwrap()
  let end_idx = log.search_by(fn(s) { s.has_prefix("control") && s.contains(" 9 0") }).unwrap()
  assert_true(exact_idx < end_idx)
}

///|
test "a player: scrub_done with at seeks directly to the exact frame without an extra near seek" {
  let m = @player.Media::new()
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=844.0)
  m.open(video("a.mp4", "video/mp4"))
  t.draw()
  let told = fn(said : String) { t.views().iter().any(fn(s) { s.has_prefix("control") && s.contains(said) }) }
  m.scrub_to(4000.0)
  assert_true(told(" 11 4000"))
  assert_false(told(" 3 4000"))
  m.scrub_done(at=6000.0)
  t.draw()
  assert_true(m.scrubbing() is None)
  assert_true(told(" 3 6000"))
  assert_false(told(" 11 6000"))
  let log = t.views()
  let exact_idx = log.search_by(fn(s) { s.has_prefix("control") && s.contains(" 3 6000") }).unwrap()
  let end_idx = log.search_by(fn(s) { s.has_prefix("control") && s.contains(" 9 0") }).unwrap()
  assert_true(exact_idx < end_idx)
}

///|
/// Its decoder given up where it has waited media_decode_wait_ms from when all its bytes came by the clock at `now`, as
/// a player's nodes give it up (at that moment of their own).
fn decode_waited(m : @player.Media, now : Double) -> Unit {
  match m.native() {
    Some(n) if n.state() == 2 &&
      n.decode_since() >= 0.0 &&
      n.decode_since() + @player.media_decode_wait_ms <= now => m.decode_given_up()
    _ => ()
  }
}

///|
test "a player waits for the decoder only after all bytes arrived, and retry starts a new wait" {
  let m = @player.Media::new()
  let t = @ui.Tester::new(fn(_c) {  }, finish=false)
  let wait = @player.media_decode_wait_ms
  let margin = wait / 40.0
  let track = video("a.webm", "video/webm")
  m.open(track)
  let id = m.native().unwrap().id()
  t.draw()
  t.run_for(wait * 1.5)
  decode_waited(m, t.time())
  assert_eq(m.status().state, 0, msg="a slow read is not a decoder timeout")
  assert_true(t.view_said("{\"info\":{\"view\":\{id},\"state\":2,\"at\":[-1,0,0,0,0,100,0,0,0,0]}}"))
  // No frames at all between the host's event and this observation.
  t.advance(wait - margin)
  t.frame_at(t.time())
  decode_waited(m, t.time())
  assert_eq(m.status().state, 0)
  t.advance(margin * 2.0)
  t.frame_at(t.time())
  decode_waited(m, t.time())
  assert_eq(m.status().state, -4)
  m.retry()
  let next = m.native().unwrap().id()
  assert_true(next != id)
  assert_true(t.view_said("{\"info\":{\"view\":\{next},\"state\":2,\"at\":[-1,0,0,0,0,100,0,0,0,0]}}"))
  t.advance(wait - margin)
  t.frame_at(t.time())
  decode_waited(m, t.time())
  assert_eq(m.status().state, 0, msg="retry gets its own wait")
  assert_true(t.view_said("{\"info\":{\"view\":\{next},\"state\":1,\"at\":[10000,0,0,640,360,100,1,0,0,0]}}"))
  t.draw()
  t.run_for(margin * 2.0)
  decode_waited(m, t.time())
  assert_eq(m.status().state, 1)
}

///|
test "a frame asked of a player is waited for only so long, and another can be asked then" {
  let m = @player.Media::new()
  let t = @ui.Tester::new(fn(_c) {  }, finish=false)
  let wait = @player.media_grab_wait_ms
  let margin = wait / 40.0
  m.open(video("a.mp4", "video/mp4"))
  let n = m.native().unwrap()
  // (waited for so long from when it was asked, by the clock at `now`)
  let stalled = fn(now : Double) { n.grab_since() >= 0.0 && n.grab_since() + wait <= now }
  t.draw()
  n.grab_frame(1000.0)
  t.draw()
  t.advance(wait - margin)
  t.frame_at(t.time())
  assert_false(stalled(t.time()))
  assert_true(n.grabbing())
  t.advance(margin * 2.0)
  t.frame_at(t.time())
  assert_true(stalled(t.time()))
  n.give_up_grab()
  assert_false(n.grabbing())
  assert_eq(n.grab_since(), -1.0)
  n.grab_frame(2000.0)
  assert_true(n.grabbing())
}

///|
test "a player opened not to play: there at its place, paused, its frame shown, until it is played" {
  let m = @player.Media::new()
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=844.0)
  let track = video("a.mp4", "video/mp4")
  m.open(track, start=4000.0, play=false)
  t.draw()
  let id = m.native().unwrap().id()
  assert_true(t.views().contains("control \{id} 3 4000"), msg="sent to its place")
  assert_true(!t.views().contains("control \{id} 1 0"), msg="not played")
  m.play_pause()
  assert_true(t.views().contains("control \{id} 1 0"), msg="played from its key")
  // (by default it plays as it opens, as ever)
  m.open(track)
  let next = m.native().unwrap().id()
  assert_true(t.views().contains("control \{next} 1 0"))
}
