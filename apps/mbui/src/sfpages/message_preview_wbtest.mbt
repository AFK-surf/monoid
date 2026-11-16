// The viewer opened from a message's picture or video made as nodes (a chat's page made as nodes: message_media_node,
// message_video_node), the viewer beside them as the shells have it (sfbase's viewer_node): it flies from the thumbnail
// and back into it as from the old view's (one picture on the screen, never two; never a frame of nothing at its
// start), a video closed keeping where it was left and the frame it showed; a video sent from here told its file as
// the core's row takes it over.
//
// Where the viewer and the player are tested, the old chat page's and the one made as nodes (what runs on both, what
// is the old one's alone and why):
//   on both pages: sfapp/flight_under_bar (a picture and a film under the bar, `nodes` both; the page made as nodes'
//     flight in and out, every frame one picture seen), sfapp/film_close_still (a film closed by back, a finger down,
//     zoomed, playing, each decode's timing, `nodes` both), and this file (the page made as nodes' pictures and films:
//     flight in and out, the first frame seen, a tall one from its top, where a film was left, played through, 全屏
//     at 0:00, Ended played again, a desktop's double click said, turned sideways a phone's, a film sent from here told
//     its file).
//   the player on both (player.mbt's and player_node.mbt's, the same inputs): sf/player_parity.
//   the old page's alone, its thumbnail an old view's (chat_file, note_thumb) where the flight, the zoom and the
//     bars are the viewer's whatever page it was opened from: sfapp/preview, preview_tree, preview_flight,
//     preview_close_corners, viewer_media, viewer_media_over, viewer_flight, viewer_big, viewer_closed,
//     viewer_fade_words, viewer_fly_words, viewer_outer, viewer_pick, viewer_viz, viewers_desk, zoom_flight,
//     pic_flight, quote_flight, flight_seen, sfbase/flight_room, viewer_first_frame, sf/viewer_bar_corner,
//     viewer_bar_gone, viewer_head_node.
//   a tab beside the page (no thumbnail): sfapp/view_beside, files_tab, tape_tab, sfpages/farview_tab.
//   a drive's (its folder's others, a subtitle beside it: the old player alone, player_node has none):
//     sf/player, player_told, sfapp/play, sfpages/drive_play.
//   the motion drives (scripts/motion: viewer, viewer-open, viewer-video, viewer-video-medium, picture-lift,
//     wide-images, send-quote-video) run the old page; on the page made as nodes they are chat_drive_parity's to run.

///|
/// The files of a message `list()` says, `top` down a column 390 wide, the viewer over them, a window `w` × `h` on
/// `platform`; their pictures decoded (a picture's its station's, a video's its station's still).
fn pv_chat(list : () -> Array[Attachment], w? : Double = 390.0, h? : Double = 844.0, platform? : Int = 1, top? : Double = 200.0) -> @ui.Tester {
  @sfbase.file_viewer_reset()
  // (its files shown once their pictures are said to decode a while after they are asked: video_tester's)
  let shown = @signals.signal(false)
  let src : Source = {
    ..files_src(),
    file: fn(_, _, name) { "mem:pv/" + name },
    poster: fn(_, _, name) { "mem:pv/" + name + ".still" },
  }
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() {
        @ui.old_views_here(c)
        @sf.presented(c)
      })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.box(fn(v) {
        v.grow(Is(1.0)) |> ignore
        let col = v.box(fn(c) { c.width(Is(Some(390.0))).padding(Is((0.0, top, 0.0, 0.0))) |> ignore })
        let popup = v.box(fn(p) { p.over(Is(true)) |> ignore })
        let tips = @sf.TipLayer::new(fn() { Some(popup) })
        message_files_node(col, src, tips, files_place(), fn() { if shown.get() { list() } else { [] } }, fn() { false }, fn() { None }, fn() { "" })
        @sfbase.viewer_node(v, src, fn() { v.window() })
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w~,
    h~,
    platform~,
    finish=true,
    images=[("mem:pv/pic.png", 800, 600), ("mem:pv/clip.mp4.still", 1280, 720)],
  )
  // (their bytes here, each decoded a moment after it is asked: video_tester's)
  @ui.add_image("mem:pv/pic.png", pv_png())
  @ui.add_image("mem:pv/clip.mp4.still", pv_png())
  t.decode_after("mem:pv/pic.png", video_test_decode)
  t.decode_after("mem:pv/clip.mp4.still", video_test_decode)
  shown.set(true)
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// A picture 16 × 9, grey (its bytes, as small as the host's bar for this file lets them be).
fn pv_png() -> Bytes {
  @pixels.png(16, 9, FixedArray::make(16 * 9 * 4, b'\x80'))
}

///|
/// The pictures drawn seen (their alpha over half): each (x, y, w, h).
fn pv_seen(t : @ui.Tester) -> Array[(Double, Double, Double, Double)] {
  t.drawn_images().filter_map(fn(i) { if i[8] > 0.5 && i[2] > 1.0 { Some((i[0], i[1], i[2], i[3])) } else { None } })
}

///|
/// Whether `a` is the box (x, y, w, h), to a point.
fn pv_at(a : (Double, Double, Double, Double), x : Double, y : Double, w : Double, h : Double) -> Bool {
  (a.0 - x).abs() < 1.0 && (a.1 - y).abs() < 1.0 && (a.2 - w).abs() < 1.0 && (a.3 - h).abs() < 1.0
}

///|
test "a picture of a chat made as nodes, pressed: the viewer flies from its thumbnail, the thumbnail hidden, its picture seen from the first frame where the thumbnail was; closed, back into it, the thumbnail shown again once it lands" {
  let t = pv_chat(fn() { [media_one()] })
  t.tap(media_test_w / 2.0, 200.0 + media_test_h / 2.0)
  let v = @sfbase.viewer.get().unwrap()
  assert_true(v.flies && !v.fly_back, msg="flies from its thumbnail")
  assert_eq(@sfbase.pv_hidden.get(), v.thumb_id())
  // its first frame: one picture seen, where the thumbnail is (never a frame of nothing, never two)
  t.draw()
  let first = pv_seen(t)
  assert_eq(first.length(), 1, msg="\{Repr(first)}")
  assert_true(pv_at(first[0], 0.0, 200.0, media_test_w, media_test_h), msg="\{Repr(first)}")
  // landed: the thumbnail its own again under the viewer
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.pv_hidden.get(), "")
  t.back()
  match @sfbase.pv_leaving.get() {
    Some(l) => assert_true(l.flies && l.fly_back, msg="back into its thumbnail")
    None => fail("closed at once")
  }
  assert_eq(@sfbase.pv_hidden.get(), v.thumb_id())
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.viewer.get() is None && @sfbase.pv_leaving.get() is None)
  assert_eq(@sfbase.pv_hidden.get(), "")
  // landed: the thumbnail alone, where it was
  t.draw()
  let last = pv_seen(t)
  assert_eq(last.length(), 1, msg="\{Repr(last)}")
  assert_true(pv_at(last[0], 0.0, 200.0, media_test_w, media_test_h), msg="\{Repr(last)}")
}

///|
/// The video of these tests' box: (360, 203), `top` down.
fn pv_video_tap(t : @ui.Tester) -> Unit {
  let (bw, bh) = video_box()
  t.tap(bw / 2.0, 200.0 + bh / 2.0)
}

///|
/// The highest native view's id the host was told of (its player's, the one open last).
fn pv_player(t : @ui.Tester) -> Int {
  t
  .views()
  .fold(init=0, fn(most, l) {
    let parts = l.split(" ").to_array()
    if parts.length() >= 2 && parts[0].to_owned() == "control" {
      let id = @string.parse_int(parts[1][:]) catch { _ => 0 }
      if id > most {
        id
      } else {
        most
      }
    } else {
      most
    }
  })
}

///|
/// The bytes in hex (a host's grabbed frame as a run's line says it: Tester::view_said).
fn pv_hex(b : Bytes) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  for x in b {
    out.write_char(digits.get_char(x.to_int() >> 4).unwrap())
    out.write_char(digits.get_char(x.to_int() & 15).unwrap())
  }
  out.to_string()
}

///|
/// How many times the host was told to seek its player to `ms`.
fn pv_seeks(t : @ui.Tester, ms : Int) -> Int {
  t.views().filter(fn(l) { l.has_prefix("control") && l.has_suffix(" 3 \{ms}") }).length()
}

///|
test "a video of a chat made as nodes, pressed: the viewer flies from its thumbnail with its still, the thumbnail hidden" {
  let t = pv_chat(fn() { [video_one()] })
  pv_video_tap(t)
  let v = @sfbase.viewer.get().unwrap()
  assert_true(v.flies && !v.fly_back, msg="flies from its thumbnail")
  assert_eq(@sfbase.pv_hidden.get(), v.thumb_id())
  t.draw()
  let (bw, bh) = video_box()
  let first = pv_seen(t)
  assert_eq(first.length(), 1, msg="\{Repr(first)}")
  assert_true(pv_at(first[0], 0.0, 200.0, bw, bh), msg="\{Repr(first)}")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.pv_hidden.get(), "")
}

///|
/// A video of a chat made as nodes opened, played to `ms`, closed: where it was left kept by its id (none: nothing kept),
/// then opened again: where its viewer starts, and how often its player was told to seek there once ready (its host
/// standing at its start).
fn pv_video_left(ms : Double) -> ((String, Double)?, Double, Int) raise {
  let t = pv_chat(fn() { [video_one()] })
  pv_video_tap(t)
  t.run_for(@ui.move_most_ms)
  let v = @sfbase.viewer.get().unwrap()
  let id = v.id()
  t.set_player(pv_player(t), position=ms)
  t.draw()
  t.back()
  // (the frame it shows asked for, the host's answer said)
  let n = pv_player(t)
  assert_true(t.views().contains("control \{n} 22 640"), msg="its frame asked for: \{Repr(t.views())}")
  assert_true(t.view_said("{\"still\":{\"view\":\{n}},\"b\":\"\{pv_hex(pv_png())}\"}"))
  t.draw()
  t.run_for(@ui.move_most_ms * 2.0)
  let kept = @sfbase.pv_frames.get(id)
  guard @sfbase.viewer.get() is None && @sfbase.pv_leaving.get() is None else { fail("not gone") }
  pv_video_tap(t)
  let again = @sfbase.viewer.get().unwrap()
  let start = again.start_at
  t.draw()
  // (its host ready at its start, the seek it was opened with not taken)
  let n = pv_player(t)
  t.set_player(n, position=0.0)
  t.draw()
  t.run_for(@ui.move_most_ms)
  (kept, start, pv_seeks(t, ms.to_int()))
}

///|
test "a video of a chat made as nodes closed 3.2 s in: where it was kept for its thumbnail; opened again, on from there" {
  let (kept, start, seeks) = pv_video_left(3200.0)
  match kept {
    Some((_, at)) => assert_eq(at, 3200.0)
    None => fail("nothing kept")
  }
  ignore(start)
  assert_true(seeks >= 1, msg="opened from there: \{seeks}")
}

///|
test "a video of a chat made as nodes closed 0.6 s in: where it was kept; opened again, on from there (under a second is no start)" {
  let (kept, start, seeks) = pv_video_left(600.0)
  match kept {
    Some((_, at)) => assert_eq(at, 600.0)
    None => fail("nothing kept")
  }
  ignore(start)
  assert_true(seeks >= 1, msg="opened from there: \{seeks}")
}

///|
test "a video's 全屏 from where a tab played it, at 0:00: from its start, not from where it was left before" {
  let t = pv_chat(fn() { [video_one()] })
  let a = video_one()
  let here = files_here()
  @sfbase.pv_frames[here.station + "/" + a.owner + "/" + a.path] = ("", 3200.0)
  @sfbase.open_preview(here.station, a.owner, a, start=0.0, beside=false)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_true(pv_player(t) > 0, msg="its player opened: \{Repr(t.views())}")
  assert_eq(pv_seeks(t, 3200), 0)
}

///|
test "a desktop's video of a chat made as nodes, double clicked on its right: 15 s on, said in its middle a moment" {
  let t = pv_chat(fn() { [video_one()] }, w=1280.0, h=800.0, platform=0)
  pv_video_tap(t)
  t.run_for(@ui.move_most_ms)
  t.set_player(pv_player(t), position=20000.0, duration=42000.0)
  t.draw()
  t.tap(1100.0, 400.0)
  t.advance(@ui.double_tap_ms / 2.0)
  t.tap(1100.0, 400.0)
  t.draw()
  let said = @sf.t("android-misc.drive.player.ahead", args=[("n", "15")])
  assert_true(t.find(said) is Some(_), msg="said: \{said}")
}

///|
test "a desktop's video of a chat made as nodes at its end, its host still saying it plays: its play key plays it again from its start" {
  let t = pv_chat(fn() { [video_one()] }, w=1280.0, h=800.0, platform=0)
  pv_video_tap(t)
  t.run_for(@ui.move_most_ms)
  let n = pv_player(t)
  t.set_player(n, position=10000.0, duration=10000.0, playing=true, ended=true)
  t.draw()
  let before = t.views().length()
  t.click(Button, label=@sf.t("web-main.video.playKey"))
  t.draw()
  let told = t.views()[before:].to_owned()
  assert_true(told.iter().any(fn(l) { l == "control \{n} 3 0" }), msg="\{Repr(told)}")
  assert_true(!told.iter().any(fn(l) { l == "control \{n} 2" || l.has_prefix("control \{n} 2 ") }), msg="paused: \{Repr(told)}")
}

///|
test "a video sent from here told its station's file as the core's row takes it over (its path, its length): its capsule says how long it is, the same nodes" {
  let sent : Attachment = { ..video_one(), upload: "u1", path: @sfbase.upload_path("u1"), duration: 0.0 }
  let cur : Ref[Attachment] = Ref(sent)
  let rev = @signals.signal(0)
  let t = pv_chat(fn() {
    rev.get() |> ignore
    [cur.val]
  })
  assert_true(t.rect_of(@sf.clock(42000.0)) is None)
  cur.val = { ..video_one(), upload: "u1" }
  rev.set(1)
  t.run_for(@ui.move_most_ms)
  assert_true(t.rect_of(@sf.clock(42000.0)) is Some(_), msg="its length said")
}

///|
test "a phone's video of a chat made as nodes turned sideways by its 全屏, its window then turned: still a phone's player, its 退出全屏 there; back turns it upright first, the viewer staying" {
  let t = pv_chat(fn() { [video_one()] }, w=390.0, h=844.0, platform=1)
  pv_video_tap(t)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label=@sf.t("android-misc.drive.player.full"))
  t.resize(844.0, 390.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label=@sf.t("android-misc.drive.player.unfull")) is Some(_), msg="a phone's 退出全屏")
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.viewer.get() is Some(_), msg="back turns it upright first, the viewer staying")
  assert_true(!@hostapi.sideways(), msg="upright")
}

///|
/// A video of a chat made as nodes opened, played to `ms` (to its end where `ended`), closed: where it was kept.
fn pv_left_after(t : @ui.Tester, ms : Double, ended? : Bool = false) -> (String, Double)? {
  pv_video_tap(t)
  t.run_for(@ui.move_most_ms)
  let id = @sfbase.viewer.get().unwrap().id()
  let n = pv_player(t)
  t.set_player(n, position=ms, duration=42000.0, ended~)
  t.draw()
  t.back()
  t.view_said("{\"still\":{\"view\":\{n}},\"b\":\"\{pv_hex(pv_png())}\"}") |> ignore
  t.draw()
  t.run_for(@ui.move_most_ms * 2.0)
  @sfbase.pv_frames.get(id)
}

///|
test "a video of a chat made as nodes played to its end and closed: opened again, from its start; taken back to its start and closed: from its start, nothing of where it was before" {
  let t = pv_chat(fn() { [video_one()] })
  match pv_left_after(t, 42000.0, ended=true) {
    Some((_, at)) => assert_eq(at, 0.0)
    None => ()
  }
  let t = pv_chat(fn() { [video_one()] })
  assert_true(pv_left_after(t, 3200.0) is Some((_, 3200.0)))
  match pv_left_after(t, 0.0) {
    Some((_, at)) => assert_eq(at, 0.0)
    None => ()
  }
}

///|
test "a tall picture of a chat made as nodes, cut from its top in its box: the viewer flies from its top and back there" {
  let tall = files_one("pic.png", width=200.0, height=4000.0)
  let t = pv_chat(fn() { [tall] })
  t.tap(60.0, 220.0)
  match @sfbase.viewer.get() {
    Some(v) => assert_true(v.flies && v.fly_from.map(fn(f) { f.start_crop }) == Some(true), msg="from its top")
    None => fail("not opened")
  }
  t.run_for(@ui.move_most_ms)
  t.back()
  match @sfbase.pv_leaving.get() {
    Some(l) => assert_true(l.fly_back && l.fly_from.map(fn(f) { f.start_crop }) == Some(true), msg="back to its top")
    None => fail("closed at once")
  }
  // (closed whole: nothing of it left to a test after this one)
  t.run_for(@ui.move_most_ms)
}
