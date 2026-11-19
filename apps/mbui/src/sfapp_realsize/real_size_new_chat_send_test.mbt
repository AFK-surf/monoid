// A new chat's first words sent on a Mac's window, on a workspace of real size, the pointer resting on the chats' list
// (2026-11-15: 300 ms hung, the core's answer to the send and the chat's first row value taken as a frame began, each
// structure that value marked settled as a change of its own at a later moment than the one before, each laying the
// tree out again where the pointer is read). The core made up here answers on its channel as a device's does
// (sffixture's round_trip_again), so that frame is the device's: each structure settled as a change of its own is a
// layout pass of its own (38 in that frame, 1,076 nodes laid, against 3 and 335 with each answer's structures settled
// as one change: Studio, 2026-11-15).

///|
/// How long the pointer rests on the chats' list before the send, and how long the frames after it are looked at: the
/// core's answer and the chat's first row value come within it (round_trip_again's at once, a frame each way).
let new_chat_send_rest_ms : Double = 500.0

///|
let new_chat_send_after_ms : Double = 2000.0

///|
/// How far the made-up core is: a device's core across its thread, a few ms.
let new_chat_send_core_ms : Double = 4.0

///|
/// As many layout passes as a frame that takes what came from outside runs at most: the frame's own, the pointer's
/// and where things stand once a change is told whole, for the change and the frame (3 the most seen, the send's own).
let new_chat_send_passes_most : Int = 8

///|
/// The window's tree's nodes laid out and its layout passes in each frame the journal holds from entry `from` on.
fn journal_laid_from(from : Int) -> Array[(Int, Int)] {
  let out : Array[(Int, Int)] = []
  for i, e in @ui.journal() {
    if i < from {
      continue
    }
    match e {
      Work({ what: Frame(f), .. }) => out.push((f.laid, f.passes))
      _ => ()
    }
  }
  out
}

///|
test "wide, a workspace of real size: a new chat's first words sent by Enter, the pointer on the chats' list: no frame after lays its tree out more than twice, nor more than a few times over" {
  // (each frame's own work counted, as a device's frames do it: what the frames drawn between at another rate do is
  // not that frame's, and the journal's ring holds too few of them)
  if @ui.test_at_a_rate() {
    return
  }
  @sfapp.reset()
  let c = @sfrealsize.RealSizeChanging::new()
  let held = c.source(@sffixture.fixture("home"))
  @sfapp.open_fixture_over("home", held)
  // (a device's core a few ms away: the send's answers and the chat's first row value come together, after the frame
  // that put the chat up asked for that row)
  let src = @sffixture.round_trip_again(held, new_chat_send_core_ms)
  // (what moves not judged frame to frame: the frames' work is what is counted here, as the real size's sweep counts
  // it, real_size_test.mbt)
  let t = @ui.Tester::new(
    fn(cx) { @sfapp.view(cx, src) },
    tree=@sfapp.app_tree(src),
    w=1280.0,
    h=800.0,
    platform=0,
    words_over_held=false,
  )
  t.drive("timeout 20000\nuntil 新建对话\ntap 新建对话\nuntil 做任何事\ntap 做任何事\ntype 把发布说明写一下\n") |> ignore
  // (the pointer come to rest on the chats' list, as the person's was: what is under it read)
  t.move_to(160.0, 300.0)
  t.run_for(new_chat_send_rest_ms)
  let from = @ui.journal().length()
  t.enter()
  t.run_for(new_chat_send_after_ms)
  let laid = journal_laid_from(from)
  assert_true(laid.length() > 0, msg="no frame drawn after the send")
  let most = laid.fold(init=0, fn(a, n) { if n.0 > a { n.0 } else { a } })
  let passes = laid.fold(init=0, fn(a, n) { if n.1 > a { n.1 } else { a } })
  // (the window's tree's nodes, made and not let go)
  let nodes = @ui.view_tree().unwrap().alive()
  println("NEW-CHAT-SEND laid \{most} of \{nodes} nodes, \{passes} passes at most, \{laid.length()} frames")
  assert_true(most <= 2 * nodes, msg="a frame after the send laid \{most} nodes out of a tree of \{nodes}")
  assert_true(
    passes <= new_chat_send_passes_most,
    msg="a frame after the send laid its tree out in \{passes} passes: a structure's change settled as one of its own",
  )
}
