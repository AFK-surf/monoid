///|
test "a thumbnail gives up on a stalled decoder only after all bytes arrive" {
  pv_first.clear()
  let image : Ref[() -> String] = Ref(fn() { "" })
  let t = @ui.Tester::new(
    fn(_) {  },
    tree=fn(root) { image.val = bytes_first_frame_node(root, "first-frame-test", "clip.webm", b"file") },
    finish=false,
  )
  let n = pv_first.get("first-frame-test").unwrap().view.unwrap()
  let id = n.id()
  let wait = @player.media_decode_wait_ms
  let margin = wait / 200.0
  t.draw()
  t.run_for(wait * 1.5)
  assert_eq((image.val)(), "", msg="a slow read is not a decoder timeout")
  assert_true(t.view_said("{\"info\":{\"view\":\{id},\"state\":2,\"at\":[-1,0,0,0,0,4,0,0,0,0]}}"))
  t.advance(wait - margin)
  t.frame_at(t.time())
  assert_eq((image.val)(), "")
  t.advance(margin * 2.0)
  t.frame_at(t.time())
  assert_eq((image.val)(), "!")
  t.draw()
  assert_true(t.views().contains("close \{id}"))
  pv_first.clear()
}

///|
test "viewer_tab_node pauses on ordinary park, stays paused on wake, and preserves playback on side-panel <-> fullscreen handoff" {
  reset()
  @sf.set_words(fill)
  let file : Attachment = {
    name: "clip.mp4",
    path: "clip.mp4",
    size: 1024.0,
    width: 640.0,
    height: 360.0,
    thumbhash: "",
    owner: "",
    upload: "",
    duration: 10.0,
    frames: 300,
    held: false,
  }
  let chat = "ws1/st1:s1"
  let tab = view_tab_key("ws1/st1", "s1", file, None, false)
  // mode: 0 = side panel active, 1 = parked (switched to another page), 2 = fullscreen handoff
  let mode = @signals.signal(0)
  let src = made_source()
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.pick_kept(at_once=true, fn() { mode.get() }, fn(slot, m) {
        if m == 0 || m == 2 {
          viewer_tab_node(slot, src, chat, tab, fn() { 400.0 }, None)
        }
      })
    },
    w=800.0,
    h=600.0,
    platform=0,
  )
  t.draw()
  let vw = tab_viewer(chat, tab).unwrap()
  let media = vw.media.unwrap()
  let nv = media.native().unwrap()
  let vid = nv.id()
  // Mark media ready & playing via FakeHost media info.
  assert_true(t.view_said("{\"info\":{\"view\":\{vid},\"state\":3,\"at\":[1000,10000,1,0,0,0,640,360,300,0]}}"))
  t.draw()
  assert_true(media.status().playing, msg="media should be playing before park")
  // Ordinary park (switch away to another page) -> automatically pauses playback.
  let pause_cmd = "control \{vid} 2 0"
  let play_cmd = "control \{vid} 1 0"
  mode.set(1)
  t.draw()
  assert_true(t.views().contains(pause_cmd), msg="ordinary park must tell native player to pause: \{Repr(t.views())}")
  assert_true(t.view_said("{\"info\":{\"view\":\{vid},\"state\":2,\"at\":[1000,10000,0,0,0,0,640,360,300,0]}}"))
  t.draw()
  assert_false(media.status().playing, msg="media must be paused after ordinary park")
  // Ordinary wake (return to side panel) -> MUST stay paused (never auto-resume).
  let plays_before_wake = t.views().filter(fn(s) { s == play_cmd }).length()
  mode.set(0)
  t.draw()
  let plays_after_wake = t.views().filter(fn(s) { s == play_cmd }).length()
  assert_eq(plays_after_wake, plays_before_wake, msg="ordinary wake must not send play to native player")
  assert_false(media.status().playing, msg="ordinary wake must keep media paused")
  // Resume playback, then explicit side-panel -> fullscreen handoff -> must NOT pause.
  media.play_pause()
  assert_true(t.view_said("{\"info\":{\"view\":\{vid},\"state\":3,\"at\":[1500,10000,1,0,0,0,640,360,300,0]}}"))
  t.draw()
  assert_true(media.status().playing, msg="media should be playing before fullscreen handoff")
  let pauses_before_handoff = t.views().filter(fn(s) { s == pause_cmd }).length()
  tab_viewer_moves(chat, tab)
  mode.set(2)
  t.draw()
  let pauses_after_handoff = t.views().filter(fn(s) { s == pause_cmd }).length()
  assert_eq(pauses_after_handoff, pauses_before_handoff, msg="side-panel -> fullscreen handoff must not pause playback")
  assert_true(media.status().playing, msg="side-panel -> fullscreen handoff must preserve playback")
  // Explicit fullscreen -> side-panel handoff -> must NOT pause.
  tab_viewer_moves(chat, tab)
  mode.set(0)
  t.draw()
  let pauses_after_return = t.views().filter(fn(s) { s == pause_cmd }).length()
  assert_eq(pauses_after_return, pauses_before_handoff, msg="fullscreen -> side-panel handoff must not pause playback")
  assert_true(media.status().playing, msg="fullscreen -> side-panel handoff must preserve playback")
  tab_viewers_reset()
  @ui.run_let_go()
}

///|
test "tab_viewer revokes on workspace owner change and tab_full_close does not set goes_on when chat left stack" {
  reset()
  @sf.set_words(fill)
  accounts_subs_sync(["acct-a", "acct-b"])
  workspace_owner_set("ws1", "acct-a")
  let file : Attachment = {
    name: "clip.mp4",
    path: "clip.mp4",
    size: 1024.0,
    width: 640.0,
    height: 360.0,
    thumbhash: "",
    owner: "",
    upload: "",
    duration: 10.0,
    frames: 300,
    held: false,
  }
  let chat = "ws1/st1:s1"
  let tab = view_tab_key("ws1/st1", "s1", file, None, false)
  let src = made_source()
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.pick_kept(at_once=true, fn() { true }, fn(slot, _) {
        viewer_tab_node(slot, src, chat, tab, fn() { 400.0 }, None)
      })
    },
    w=800.0,
    h=600.0,
    platform=0,
  )
  t.draw()
  let tv_a = tab_viewers.get(tab_viewer_id(chat, tab)).unwrap()
  assert_eq(tv_a.owner, "acct-a")
  let vid_a = tv_a.viewer.media.unwrap().native().unwrap().id()
  assert_true(t.view_said("{\"info\":{\"view\":\{vid_a},\"state\":3,\"at\":[2000,10000,1,0,0,0,640,360,300,0]}}"))
  t.draw()
  // Closing fullscreen when chat is not on nav stack must NOT set goes_on.
  let chat_ref : ChatRef = { station: "ws1/st1", session: "s1", title: "C1", station_name: "st1" }
  tab_full.set(Some({ chat: chat_ref, tab }))
  full_lone.val = false
  tab_full_close()
  assert_false(tv_a.goes_on, msg="tab_full_close must not set goes_on when chat is not on nav stack")
  // Chat IS on nav stack, but covered by another page (Settings) -> tab_full_close must still NOT set goes_on!
  app.nav.push(Chat(chat_ref))
  app.nav.push(Settings)
  tab_full.set(Some({ chat: chat_ref, tab }))
  full_lone.val = false
  tab_full_close()
  assert_false(tv_a.goes_on, msg="tab_full_close must not set goes_on when chat is covered by another page")
  // When chat IS the foreground top page -> tab_full_close DOES preserve playback (sets goes_on),
  // AND if no node takes over by after_drawn_frame (e.g. layout tears down fullscreen without mounting side panel),
  // the end-of-frame fallback resets goes_on and pauses playback so audio never leaks.
  app.nav.pop() |> ignore
  tab_full.set(Some({ chat: chat_ref, tab }))
  full_lone.val = false
  tab_full_close()
  assert_true(tv_a.goes_on, msg="tab_full_close must set goes_on when chat is the foreground page")
  tv_a.drawn = 0
  let pause_cmd = "control \{vid_a} 2 0"
  let pauses_before = t.views().filter(fn(s) { s == pause_cmd }).length()
  t.draw()
  assert_false(tv_a.goes_on, msg="after_drawn_frame fallback must clear goes_on when no node took over")
  assert_true(
    t.views().filter(fn(s) { s == pause_cmd }).length() > pauses_before,
    msg="after_drawn_frame fallback must pause player when no node took over",
  )
  tv_a.drawn = 1
  // Failed handoff where original node stays mounted (`drawn > 0`) through frame end:
  // `goes_on` must unconditionally expire at after_drawn_frame so a subsequent park/hide pauses playback!
  assert_true(t.view_said("{\"info\":{\"view\":\{vid_a},\"state\":3,\"at\":[2500,10000,1,0,0,0,640,360,300,0]}}"))
  t.draw()
  tab_viewer_moves(chat, tab)
  assert_true(tv_a.goes_on)
  t.draw()
  assert_false(tv_a.goes_on, msg="unconsumed goes_on must unconditionally expire at frame end even when drawn > 0")
  // Workspace owner revocation synchronously pauses & releases old TabViewer AND unmounts mounted viewer_tab_node.
  assert_true(t.find("clip.mp4") is Some(_), msg="viewer_tab_node should be mounted before revocation")
  workspace_owner_set("ws1", "acct-b")
  assert_true(tab_viewers.is_empty(), msg="revoked owner TabViewer must be removed on workspace owner change")
  assert_true(t.views().contains("close \{vid_a}"), msg="revoked owner TabViewer native player must be closed")
  t.draw()
  assert_true(t.find("clip.mp4") is None, msg="mounted viewer_tab_node must unmount cleanly on owner revocation")
  tab_viewers_reset()
  @ui.run_let_go()
}
