// The one player (player_node.mbt, as a drive's page has it: player_opened) over the fake host (src/ui/tester.mbt: every view there is ready, 10 s long, 640 × 360,
// paused): a phone's and a desktop's, watched and looked at closely.

///|
test "a media type names a known format but does not guess an unknown one" {
  assert_eq(player_format(" VIDEO/WEBM; codecs=vp9 "), Some("WebM"))
  assert_eq(player_format("video/3gpp"), Some("3GP"))
  assert_eq(player_format("video/3gpp2"), Some("3G2"))
  assert_true(player_format("application/octet-stream") is None)
}

///|
/// A film (or a song) of a folder, as a viewer opens it: played as it comes (the fake host's view needs no bytes);
/// what its message says of it, `facts`.
fn film(name : String, kind? : String = "video", facts? : FileFacts = no_facts) -> ViewerFile {
  {
    name,
    size: 1000.0,
    mtime: 0.0,
    mime: if kind == "audio" { "audio/mpeg" } else { "video/mp4" },
    kind,
    title: "",
    key: name,
    bytes: None,
    read: fn(_, _, done) { done(Err("")) },
    stream: Some(fn(_, _, _) { fn() {  } }),
    direct: "",
    beside: None,
    place: fn() { NeverLeft },
    keep_place: fn(_, _) {  },
    save: fn() {  },
    facts,
  }
}

///|
/// The app's words for what these tests read (the app tells the library its own as it starts).
let test_words : Map[String, String] = {
  "web-pages.drive.player.held": "2× 播放中",
  "web-pages.drive.player.nextIn": "{n} 秒后播放",
  "android-misc.drive.player.nextOne": "下一个：{name}",
  "android-misc.drive.player.ended": "播放结束",
  "android-chat.video.frames": "{at} / {n} 帧",
  "android-chat.video.scrubFrame": "逐帧",
  "android-chat.video.scrubFine": "微调",
  "common.cancel": "取消",
}

///|
/// The player of `name` among `list` (a folder's films), a phone's (`narrow`: laid out Small) or a desktop's (on a
/// Mac), what it went to and how often it went back counted; or in `window` (its width, height and platform);
/// `subtitled`, a subtitle beside it the folder names (read as nothing); `keyed`: hosted in a node of the window's
/// tree under the player's keymap (player_bindings), as the app hosts it, its keys its actions; else no keymap over it;
/// `pin`, how it stands pinned from its first frame (as a fixture's).
fn player_tester(
  narrow : Bool,
  name : String,
  list : Array[String],
  gone : Array[String],
  backs : Array[Int],
  kind? : String = "video",
  facts? : FileFacts = no_facts,
  window? : (Double, Double, Int),
  subtitled? : Bool = false,
  keyed? : Bool = false,
  pin? : @player.MediaStatus,
  dark? : Bool = false,
) -> @ui.Tester {
  let (w, h, platform) = window.unwrap_or(if narrow { (390.0, 844.0, 1) } else { (1280.0, 800.0, 0) })
  set_viewer_host(viewer_host_default())
  set_words(fn(key, args) {
    args.fold(init=test_words.get(key).unwrap_or(key), fn(said, a) { said.replace_all(old="{" + a.0 + "}", new=a.1) })
  })
  let siblings : Array[ViewerEntry] = list.map(fn(n) { { name: n, size: 1.0, mtime: 0.0, mime: "", kind, dir: false } })
  let file = film(name, kind~, facts~)
  let file = if subtitled { { ..file, beside: Some(fn(_, _) {  }) } } else { file }
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h~, dark~, platform~)
  set_dark(Some(dark))
  // (how it stands pinned from its first frame, as a fixture's: what its nodes are made by)
  match pin {
    Some(s) => playing_for("k").media.pin(s)
    None => ()
  }
  @ui.set_view_app(fn(root) {
    if keyed {
      root.keymap(Is(@view.Keymap::new(player_bindings()))) |> ignore
    }
    root.box(fn(n) {
      n.grow(Is(1.0)) |> ignore
      let m = player_opened(n, "k", file, fn() { siblings })
      player_node(
        n,
        m,
        file,
        fn() { n.window() },
        back_label=fn() { "影片" },
        on_back=fn() { backs.push(1) },
        still=fn() { "" },
        flying=fn() { false },
        going=fn() { false },
        move_beside=fn() { None },
        list=fn() { playlist_for(file, siblings) },
        on_go=fn(n) { gone.push(n) },
      )
      |> ignore
    })
    |> ignore
  })
  t
}

///|
/// Whether the fake host was told `op` (1 play, 2 pause, 3 seek, 4 rate, 9 a finger along it, 10 how loud, 11 seek to
/// about there…) of a view, with `value` (as it prints it) when given.
fn told(t : @ui.Tester, op : Int, value? : String = "") -> Bool {
  t.views().iter().any(fn(s) { s.has_prefix("control") && s.contains(" \{op} " + value) })
}

///|
test "a phone's: its name and which of the folder's, the time; the film edge to edge in the middle, on black" {
  let t = player_tester(true, "E2.mp4", ["E1.mp4", "E2.mp4", "E3.mp4"], [], [])
  t.draw()
  assert_true(t.find("E2.mp4") is Some(_))
  assert_true(t.find("2 / 3") is Some(_))
  // 640 × 360 enlarged to the 390 width, in the middle
  let holes = t.holes()
  assert_eq(holes.length(), 1)
  let (_, y, w, h) = holes[0]
  assert_true((w - 390.0).abs() < 1.0, msg="\{w}")
  assert_true((h - 219.375).abs() < 1.0, msg="\{h}")
  assert_true((y - (844.0 - 219.375) / 2.0).abs() < 1.0, msg="\{y}")
  // asked to play once opened
  assert_true(told(t, 1))
}

///|
test "a phone's, paused: its controls step a frame back and on, to the frame's time to the millisecond" {
  let t = player_tester(true, "a.mp4", [], [], [])
  t.draw()
  // (the fake view stays paused: its frames' keys show, a 60th of a second each without the file's)
  let on = t.locate("icon:chevron-right")
  assert_true(on.length() > 0)
  let (x, y) = on[0]
  t.tap(x, y)
  assert_true(told(t, 3, value="16.6"))
  // the time to the millisecond, no frame count: the file's frames were not read
  assert_true(t.find("0:00.0") is Some(_))
  assert_true(t.find(" 帧") is None)
}

///|
/// The fake host told the film's frames: ten, a tenth of a second each, 1 s long.
fn ten_frames(t : @ui.Tester) -> Unit {
  t.set_player(1, duration=1000.0, playing=true)
  t.view_said("{\"view\":{\"view\":1,\"what\":1,\"text\":\"0,100,200,300,400,500,600,700,800,900\"}}") |> ignore
}

///|
test "a desktop's timeline dragged: paused, the picture going to the start of each frame it comes to, played again once let go" {
  let t = player_tester(false, "a.mp4", [], [], [])
  t.draw()
  ten_frames(t)
  t.draw()
  guard t.all(Slider, label="web-pages.drive.player.position") is [line] else { fail("its timeline") }
  let (x, y, w, h) = line.rect
  let at = fn(k : Double) { (x + w * k, y + h / 2.0) }
  let (x0, y0) = at(0.25)
  t.press_at(x0, y0)
  // (held a frame: through the time from where it went down, as a frame drawn while it is down sees it held)
  t.run_for(@ui.frame_period_default)
  assert_true(told(t, 2))
  assert_true(told(t, 9, value="1"))
  assert_true(told(t, 3, value="200"))
  assert_false(told(t, 11, value="200"))
  let (x1, y1) = at(0.75)
  t.move_to(x1, y1)
  assert_true(told(t, 3, value="700"))
  assert_false(told(t, 11, value="700"))
  // the frame it is at, of how many, while the finger is on it
  assert_true(t.find("8 / 10 帧") is Some(_))
  t.release(x1, y1)
  t.draw()
  assert_true(told(t, 9, value="0"))
  assert_true(told(t, 1))
}

///|
/// How the player stands, pinned (as a fixture's): playing at `position` of 10 s, or at its end.
fn pinned(position : Double, ended? : Bool = false) -> @player.MediaStatus {
  {
    state: 1,
    duration: 10000.0,
    position,
    buffered: 10000.0,
    playing: !ended,
    buffering: false,
    ended,
    width: 640.0,
    height: 360.0,
  }
}

///|
test "a phone's: held still it plays at 2× until let go, then as it was" {
  let t = player_tester(true, "a.mp4", [], [], [], pin=pinned(1000.0))
  t.draw()
  t.press_at(195.0, 300.0)
  t.run_for(@ui.long_press_ms)
  assert_true(t.find("2× 播放中") is Some(_))
  assert_true(told(t, 4, value="2"))
  t.release(195.0, 300.0)
  assert_true(t.find("2× 播放中") is None)
  assert_true(told(t, 4, value="1"))
}

///|
test "at its end the next one plays a moment after, its seconds counted down, unless let go" {
  let gone = []
  let t = player_tester(true, "E1.mp4", ["E1.mp4", "E2.mp4"], gone, [], pin=pinned(10000.0, ended=true))
  t.draw()
  assert_true(t.find("下一个：E2.mp4") is Some(_))
  assert_true(t.find("5 秒后播放") is Some(_))
  t.run_for(player_second_ms)
  assert_true(t.find("4 秒后播放") is Some(_))
  t.run_for(player_next_ms - player_second_ms)
  assert_eq(gone, ["E2.mp4"])
  // let go: no next
  let gone2 = []
  let u = player_tester(true, "E1.mp4", ["E1.mp4", "E2.mp4"], gone2, [], pin=pinned(10000.0, ended=true))
  u.draw()
  u.tap_text("取消")
  u.run_for(player_next_ms)
  assert_eq(gone2.length(), 0)
  assert_true(u.find("下一个：E2.mp4") is None)
}

///|
test "at its end 选集 opened: the card goes at once and the next one is let go, played neither while it is open nor once it closes" {
  for narrow in [true, false] {
    let gone = []
    let t = player_tester(narrow, "E1.mp4", ["E1.mp4", "E2.mp4"], gone, [], pin=pinned(10000.0, ended=true))
    t.draw()
    assert_true(t.find("播放结束") is Some(_))
    t.click(Button, label="web-pages.drive.player.list")
    assert_true(t.find("播放结束") is None)
    t.run_for(player_next_ms * 2.0)
    assert_eq(gone.length(), 0)
    // closed (as the system's bars close it too): the card not back, nothing played
    player_list_toggle("k")
    t.run_for(player_next_ms * 2.0)
    assert_eq(gone.length(), 0)
    assert_true(t.find("播放结束") is None)
  }
}

///|
test "a desktop's with 选集 open beside it as it ends: the card comes and the next one plays a moment after, as with it shut" {
  let gone = []
  let t = player_tester(false, "E1.mp4", ["E1.mp4", "E2.mp4"], gone, [])
  t.draw()
  t.set_player(1, position=5000.0, duration=10000.0, playing=true)
  t.draw()
  t.click(Button, label="web-pages.drive.player.list")
  t.set_player(1, position=10000.0, duration=10000.0, playing=false, ended=true)
  t.draw()
  assert_true(t.find("播放结束") is Some(_))
  t.run_for(player_next_ms)
  assert_eq(gone, ["E2.mp4"])
}

///|
test "a phone's: a finger down the film takes it away with it, past 120 back" {
  let backs = []
  let t = player_tester(true, "a.mp4", [], [], backs)
  t.draw()
  t.drag(195.0, 300.0, 195.0, 500.0)
  assert_eq(backs.length(), 1)
}

///|
test "a phone's: a finger along the film moves through the time, the player sent there as it lets go" {
  let t = player_tester(true, "a.mp4", [], [], [])
  t.draw()
  t.drag(100.0, 300.0, 300.0, 300.0)
  assert_true(told(t, 3))
}

///|
test "a phone's song: its mark and name in the middle, on the page's colours, the controls staying" {
  let t = player_tester(true, "曲.mp3", [], [], [], kind="audio")
  t.draw()
  t.run_for(@player.media_rest_ms + @player.media_sleep_ms)
  assert_true(t.find("0:00 / 0:10") is Some(_))
  assert_true(t.find_last("曲.mp3") is Some(_))
}

///|
test "a desktop's: a pointer click alone never plays or pauses it; a double click in its middle does, once" {
  let t = player_tester(false, "E1.mp4", [], [], [])
  t.host_says_finger(Some(false))
  t.draw()
  // (what the player has been told to do: a play is op 1, a pause op 2)
  let plays = fn() {
    t.views().filter(fn(s) {
      let w = s.split(" ").to_array()
      w.length() > 2 && w[0] == "control" && (w[2] == "1" || w[2] == "2")
    }).length()
  }
  let before = plays()
  // A click alone: its controls, never its play
  t.tap(640.0, 400.0)
  t.run_for(@ui.double_tap_ms + 10.0)
  assert_eq(plays(), before)
  // A second click at the same spot within a double click's time: played or paused at that second, once
  t.tap(640.0, 400.0)
  t.advance(@ui.double_tap_ms / 2.0)
  t.tap(640.0, 400.0)
  t.draw()
  assert_eq(plays(), before + 1)
}

///|
test "a desktop's keys: Space plays, paused ← → step a frame, J L 15 s, ↑ the sound, M mutes, ⇧N the next one" {
  let gone = []
  let t = player_tester(false, "E1.mp4", ["E1.mp4", "E2.mp4"], gone, [], keyed=true)
  t.draw()
  t.key(@ui.key_space)
  assert_true(told(t, 1))
  t.key(@ui.key_code_right)
  assert_true(told(t, 3, value="16.6"))
  t.key(@ui.key_of_char('l'))
  assert_true(told(t, 11, value="10000") || told(t, 11, value="9900"))
  t.key(@ui.key_code_down)
  assert_true(told(t, 10, value="0.95"))
  t.key(@ui.key_of_char('m'))
  t.key(@ui.key_of_char('n'), mods=@ui.mod_shift_key)
  assert_eq(gone, ["E2.mp4"])
}

///|
test "a desktop's: a film on black, the bar on it in its words; its speeds a menu, 0.25× picked" {
  let t = player_tester(false, "a.mp4", [], [], [])
  t.draw()
  t.tap_text("1×")
  assert_true(t.find("0.25×") is Some(_))
  t.tap_text("0.25×")
  assert_true(told(t, 4, value="0.25"))
}

///|
test "a desktop's: the bar's way back under the pointer uses theme hover in light mode and dark media hover in dark mode" {
  defer { set_dark(None) }
  // Light mode: floating bar follows theme-light hover.
  let t = player_tester(false, "a.mp4", [], [], [], dark=false)
  t.host_says_finger(Some(false))
  t.draw()
  let (x, y) = t.find("影片").unwrap()
  let under = fn(tester : @ui.Tester, colour : Int64) {
    tester.drawn_rects().iter().any(fn(r) { r.4 == colour && r.0 <= x && x <= r.0 + r.2 && r.1 <= y && y <= r.1 + r.3 })
  }
  let light_hover = theme().p.hover
  assert_false(under(t, light_hover))
  t.move_to(x, y)
  t.frame()
  assert_true(under(t, light_hover))
  // Dark mode: floating bar uses dark media hover on the black stage.
  let td = player_tester(false, "a.mp4", [], [], [], dark=true)
  td.host_says_finger(Some(false))
  td.draw()
  let (dx, dy) = td.find("影片").unwrap()
  let under_d = fn(colour : Int64) {
    td.drawn_rects().iter().any(fn(r) { r.4 == colour && r.0 <= dx && dx <= r.0 + r.2 && r.1 <= dy && dy <= r.1 + r.3 })
  }
  let dark_lit = alpha(media_dark_text, media_hot_share)
  assert_false(under_d(dark_lit))
  td.move_to(dx, dy)
  td.frame()
  assert_true(under_d(dark_lit))
}

///|
test "a desktop's: the bar says the film's size, length and rate as its message does, before the host has read them; else the host's" {
  let facts : FileFacts = { width: 1280.0, height: 720.0, duration: 12500.0, frames: 375 }
  let t = player_tester(false, "a.mp4", [], [], [], facts~)
  t.draw()
  // (the fake host's view: 640 × 360, 10 s, its frames not read)
  assert_true(t.find("1280×720 · 0:13 · 30 fps") is Some(_))
  assert_true(t.find("640×360") is None)
  let t = player_tester(false, "a.mp4", [], [], [])
  t.draw()
  assert_true(t.find("640×360 · 0:10") is Some(_))
}

///|
test "a desktop's on a narrow stage: short of room for its keys, 保存此帧 leaves them for their ⋯" {
  // short of a little room (选集 docked beside a stage 760 wide; a finger's, no volume line beside the sound's key):
  // 保存此帧 leaves first, the speed still on the row
  let t = player_tester(false, "E1.mp4", ["E1.mp4", "E2.mp4", "E1.srt"], [], [], window=(760.0, 900.0, 2), subtitled=true)
  t.draw()
  assert_true(t.query(Slider, label="web-pages.drive.player.volume") is None)
  t.click(Button, label="web-pages.drive.player.list")
  assert_true(t.query(Button, label="android-chat.video.saveFrame") is None)
  // (the speed the last to go)
  assert_true(t.find("1×") is Some(_))
  t.click(Button, label="web-main.menu.more")
  assert_true(t.find("android-chat.video.saveFrame") is Some(_))
  // shorter still (beside a stage 690 wide), the speed gone to the ⋯ too, its speeds under their name there (the old
  // view left its 1× in its draw list at no size)
  let t = player_tester(false, "E1.mp4", ["E1.mp4", "E2.mp4", "E1.srt"], [], [], window=(690.0, 900.0, 2), subtitled=true)
  t.draw()
  t.click(Button, label="web-pages.drive.player.list")
  assert_true(t.query(Button, label="android-chat.video.saveFrame") is None)
  assert_true(t.find("1×") is None)
  t.click(Button, label="web-main.menu.more")
  assert_true(t.find("android-chat.video.saveFrame") is Some(_))
  assert_true(t.find("web-pages.drive.player.rate") is Some(_))
}

///|
test "a frame the host never gives is given up by the app's clock, told as failed, and can be asked again" {
  let t = player_tester(false, "a.mp4", ["a.mp4"], [], [])
  let said : Array[String] = []
  set_viewer_host({ ..viewer_host_default(), say: fn(s) { said.push(s) } })
  t.draw()
  t.click(Button, label="android-chat.video.saveFrame")
  t.draw()
  assert_eq(said.length(), 0)
  t.run_for(@player.media_grab_wait_ms / 2.0)
  assert_eq(said.length(), 0)
  t.run_for(@player.media_grab_wait_ms)
  assert_eq(said, ["android-chat.video.saveFrame.failed"])
  t.click(Button, label="android-chat.video.saveFrame")
  t.draw()
  assert_true(t.view_said("{\"still\":{\"view\":1},\"b\":\"89504e47\"}"))
  t.draw()
  t.run_for(@player.media_grab_wait_ms * 2.0)
  assert_eq(said.length(), 1)
}

///|
test "the player's volume read out as a slider whose range is its least, where it is, its most, and told so to the host" {
  let tt = player_tester(false, "a.mp4", [], [], [])
  playing_for("k").media.set_volume(0.4)
  tt.draw()
  let s = tt.get(Slider, label=t("web-pages.drive.player.volume"))
  assert_eq(s.range, Some((desk_none, 0.4, desk_whole)))
  // (its own of the player's sliders: the timeline is one too)
  let told = tt.ctx().a11y_lines().split("\n").filter(fn(l) { l.contains("Slider") && l.contains(t("web-pages.drive.player.volume")) }).to_array()
  assert_eq(told.length(), 1)
  let f = told[0].split("\u{1F}").map(fn(v) { v.to_owned() }).to_array()
  assert_eq([f[12], f[13], f[14]], [desk_none.to_string(), (0.4).to_string(), desk_whole.to_string()])
}

///|
test "a song's end and its failure on the page's own colours: their cards' buttons the theme's, not the night's" {
  let under = fn(t : @ui.Tester, label : String, colour : Int64) {
    match t.find(label) {
      Some((x, y)) =>
        t.drawn_rects().iter().any(fn(r) { r.4 == colour && r.0 <= x && x <= r.0 + r.2 && r.1 <= y && y <= r.1 + r.3 })
      None => false
    }
  }
  let ended = player_tester(true, "E1.mp3", ["E1.mp3", "E2.mp3"], [], [], kind="audio", pin=pinned(10000.0, ended=true))
  ended.draw()
  assert_true(ended.find("播放结束") is Some(_))
  // 下一个 on the theme's primary, 取消 on the chip's: not the night's white and its plain
  assert_true(under(ended, "android-misc.drive.player.next", theme().p.primary), msg="下一个 on the primary")
  assert_true(under(ended, "取消", theme().p.chip), msg="取消 on the chip's ground")
  let failed = player_tester(true, "曲.mp3", [], [], [], kind="audio", pin={ ..pinned(1000.0), state: -1, playing: false })
  failed.draw()
  assert_true(under(failed, "android-misc.drive.player.retry", theme().p.primary), msg="重试 on the primary")
}

///|
test "what it waits on is said in its bar beside its name, a phone's and a desktop's, never over the middle of the film" {
  let buffering : @player.MediaStatus = { ..pinned(1000.0), buffered: 1000.0, buffering: true }
  for narrow in [true, false] {
    let t = player_tester(narrow, "a.mp4", [], [], [], pin=buffering)
    t.draw()
    assert_true(t.find("web-pages.drive.player.buffering") is None, msg="narrow \{narrow}: not said before it has waited")
    t.run_for(playing_for("k").media.times().0)
    match t.find("web-pages.drive.player.buffering") {
      Some((_, y)) => assert_true(y < 100.0, msg="narrow \{narrow}: said in its bar along the top, at \{y}")
      None => fail("narrow \{narrow}: not said once it has waited")
    }
  }
}

///|
/// What the audit finds of a phone's bar along the top: the faults whose first box stands in its 100 points (its
/// controls at the foot have their own).
fn top_bar_faults(t : @ui.Tester) -> Array[String] {
  t
  .audit()
  .filter(fn(f) {
    match f.find("(at ") {
      Some(i) => {
        let at = f.unsafe_substring(start=i + 4, end=f.length())
        let xy = at.unsafe_substring(start=0, end=at.find(" ").unwrap_or(at.length()))
        match xy.find(",") {
          Some(j) => {
            // (under 100: two digits at most before its point, if it has one)
            let y = xy.unsafe_substring(start=j + 1, end=xy.length())
            y.find(".").unwrap_or(y.length()) <= 2
          }
          None => false
        }
      }
      None => false
    }
  })
}

///|
test "a phone's bar along the top splits left, centered title, and right into separate liquid glass capsules: pressed, lit, the audit clean" {
  // Single video (no playlist): two symmetric 44×44 circular glass buttons with a floating glass title capsule strictly between them.
  let t1 = player_tester(true, "a-very-long-recording-name-for-narrow-phone-preview.mp4", [], [], [])
  t1.draw()
  let pills1 = t1
    .drawn_glass_corners()
    .filter(fn(r) { (r.3 - phone_top_pill_h).abs() < 0.5 && r.1 < 200.0 })
  assert_eq(pills1.length(), 3, msg="single video top pills: \{Repr(pills1)}")
  pills1.sort_by(fn(a, b) { a.0.compare(b.0) })
  let half = phone_top_pill_h / 2.0
  let left_pill = pills1[0]
  let title_pill = pills1[1]
  let right_pill = pills1[2]
  for p in [left_pill, right_pill] {
    assert_true((p.2 - phone_top_pill_h).abs() < 0.5, msg="symmetric circle width: \{Repr(p)}")
    assert_eq(p.4, half)
  }
  assert_eq(title_pill.4, half)
  assert_true(
    title_pill.0 >= left_pill.0 + left_pill.2 && title_pill.0 + title_pill.2 <= right_pill.0 + 0.5,
    msg="title pill \{Repr(title_pill)} must sit between left \{Repr(left_pill)} and right \{Repr(right_pill)}",
  )
  assert_eq(top_bar_faults(t1), [])
  // Title text sits strictly inside the centered title capsule.
  let title_box = t1.rect_of("a-very-long").unwrap_or_else(fn() {
    match t1.all(Text, label="a-very-long-recording-name-for-narrow-phone-preview.mp4") {
      [n, ..] => n.rect
      [] => (0.0, 0.0, 0.0, 0.0)
    }
  })
  assert_true(title_box.2 > 0.0, msg="title drawn: \{Repr(title_box)}")
  assert_true(
    title_box.0 >= title_pill.0 && title_box.0 + title_box.2 <= title_pill.0 + title_pill.2 + 0.5,
    msg="title \{Repr(title_box)} must sit inside title pill \{Repr(title_pill)}",
  )
  // Playlist video: left 44×44 back circle + centered title capsule + right 2-key capsule (选集 + 下载), concentric keys, title centered, audit clean.
  let t = player_tester(true, "E2.mp4", ["E1.mp4", "E2.mp4", "E3.mp4"], [], [])
  t.draw()
  let pills = t
    .drawn_glass_corners()
    .filter(fn(r) { (r.3 - phone_top_pill_h).abs() < 0.5 && r.1 < 200.0 })
  assert_eq(pills.length(), 3, msg="playlist top pills: \{Repr(pills)}")
  pills.sort_by(fn(a, b) { a.0.compare(b.0) })
  let lp = pills[0]
  let tp = pills[1]
  let rp = pills[2]
  assert_true((lp.2 - phone_top_pill_h).abs() < 0.5, msg="left back circle: \{Repr(lp)}")
  assert_true(tp.0 >= lp.0 + lp.2 && tp.0 + tp.2 <= rp.0 + 0.5, msg="playlist title pill between sides: \{Repr(tp)}")
  assert_true(rp.2 > phone_top_pill_h + 20.0 && rp.2 < 120.0, msg="right 2-key capsule: \{Repr(rp)}")
  assert_eq(lp.4, half)
  assert_eq(tp.4, half)
  assert_eq(rp.4, half)
  // Short title stays horizontally centered on screen even with 2 right-side buttons
  let title_pl = t.rect_of("E2.mp4").unwrap()
  let title_cx = title_pl.0 + title_pl.2 / 2.0
  assert_true((title_cx - 195.0).abs() < 1.0, msg="playlist title centered: cx=\{title_cx} rect=\{Repr(title_pl)}")
  assert_eq(top_bar_faults(t), [])
  // the back key and 下载 held down, each drawing its press's round ground and ripple in its capsule
  for icon in ["icon:chevron-left", "icon:download"] {
    let (x, y) = t.locate(icon).filter(fn(p) { p.1 < 100.0 })[0]
    t.press_at(x, y)
    t.run_for(press_whole_ms)
    let faults = top_bar_faults(t)
    assert_true(faults.is_empty(), msg="\{icon} held: " + faults.join("\n"))
    // (let go off it, nothing done)
    t.release(x, y + 300.0)
    t.run_for(feel_past_ms)
  }
  // 选集 lit, its list open
  let (x, y) = t.locate("icon:list").filter(fn(p) { p.1 < 100.0 })[0]
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  let faults = top_bar_faults(t)
  assert_true(faults.is_empty(), msg="选集 lit: " + faults.join("\n"))
}

///|
test "phone top bar: buffering never shifts title or buttons, and 2.0x playlist keeps button y pinned and HUD clear" {
  // 1. Buffering toggles on: title y and top buttons y must not shift by even 0.01pt
  let buffering : @player.MediaStatus = { ..pinned(1000.0), buffered: 1000.0, buffering: true }
  let tb = player_tester(true, "clip.mp4", [], [], [], pin=buffering)
  tb.draw()
  let title_before = tb.rect_of("clip.mp4").unwrap()
  let back_before = tb.get(Button, label="common.back").rect
  let dl_before = tb.get(Button, label="web-main.preview.download").rect
  assert_true((title_before.0 + title_before.2 / 2.0 - 195.0).abs() < 1.0, msg="single video title centered")
  tb.run_for(playing_for("k").media.times().0)
  let wait_pos = tb.find("web-pages.drive.player.buffering").unwrap()
  assert_true(wait_pos.1 > title_before.1 + title_before.3 && wait_pos.1 < 100.0, msg="buffering below title: \{wait_pos.1}")
  let title_after = tb.rect_of("clip.mp4").unwrap()
  let back_after = tb.get(Button, label="common.back").rect
  let dl_after = tb.get(Button, label="web-main.preview.download").rect
  assert_true((title_after.1 - title_before.1).abs() < 0.01, msg="title y shifted on buffering: \{title_before.1} -> \{title_after.1}")
  assert_true((back_after.1 - back_before.1).abs() < 0.01, msg="back y shifted on buffering")
  assert_true((dl_after.1 - dl_before.1).abs() < 0.01, msg="download y shifted on buffering")
  // 2. 2.0x font scale + playlist: buttons stay pinned at top y, zero outgrown/squeeze faults, AlongTime HUD clears 2-line title
  let tp = player_tester(true, "E2.mp4", ["E1.mp4", "E2.mp4", "E3.mp4"], [], [])
  tp.draw()
  let back_y1 = tp.get(Button, label="common.back").rect.1
  let dl_y1 = tp.get(Button, label="web-main.preview.download").rect.1
  tp.set_font_scale(2.0)
  tp.draw()
  let back_y2 = tp.get(Button, label="common.back").rect.1
  let dl_y2 = tp.get(Button, label="web-main.preview.download").rect.1
  assert_true((back_y2 - back_y1).abs() < 0.01, msg="back button y pinned at 2.0x: \{back_y1} -> \{back_y2}")
  assert_true((dl_y2 - dl_y1).abs() < 0.01, msg="download button y pinned at 2.0x: \{dl_y1} -> \{dl_y2}")
  assert_eq(tp.fixed_outgrown(), [], msg="2.0x playlist fixed_outgrown")
  assert_eq(tp.squeeze_faults(), [], msg="2.0x playlist squeeze_faults")
  let which_rect = tp.rect_of("2 / 3").unwrap()
  let title_bottom = which_rect.1 + which_rect.3
  tp.press_at(100.0, 300.0)
  tp.move_to(140.0, 300.0)
  tp.draw()
  let hud = tp.rect_of("1×").unwrap()
  assert_true(hud.1 > title_bottom, msg="2.0x AlongTime HUD y=\{hud.1} must clear 2-line title bottom=\{title_bottom}")
  tp.release(140.0, 300.0)
}

///|
test "player_node speed capsule: 1.0x keeps exact media_rate_h / phone_key_side; 2.0x scales without fixed_outgrown or squeeze_faults" {
  // Desktop (non-phone) speed capsule
  let td = player_tester(false, "E1.mp4", ["E1.mp4"], [], [])
  td.draw()
  let hd0 = td.get(Button, label="web-pages.drive.player.rate").rect.3
  assert_eq(hd0, media_rate_h, msg="desktop 1.0x speed height")
  assert_eq(td.fixed_outgrown(), [], msg="desktop 1.0x fixed_outgrown")
  assert_eq(td.squeeze_faults(), [], msg="desktop 1.0x squeeze_faults")
  td.set_font_scale(2.0)
  td.draw()
  let hd2 = td.get(Button, label="web-pages.drive.player.rate").rect.3
  let player_outgrown = fn(t : @ui.Tester) {
    t.fixed_outgrown().filter(fn(f) { !f.contains("viewer_bar_node.mbt") })
  }
  assert_true(hd2 > media_rate_h, msg="desktop 2.0x speed height grew: \{hd2}")
  assert_eq(player_outgrown(td), [], msg="desktop 2.0x fixed_outgrown: \{Repr(player_outgrown(td))}")
  assert_eq(td.squeeze_faults(), [], msg="desktop 2.0x squeeze_faults: \{Repr(td.squeeze_faults())}")
  // Phone speed capsule
  let tp = player_tester(true, "E1.mp4", ["E1.mp4"], [], [])
  tp.draw()
  let hp0 = tp.get(Button, label="android-misc.drive.player.speed").rect.3
  assert_eq(hp0, phone_key_side, msg="phone 1.0x speed height")
  assert_eq(tp.fixed_outgrown(), [], msg="phone 1.0x fixed_outgrown")
  assert_eq(tp.squeeze_faults(), [], msg="phone 1.0x squeeze_faults")
  tp.set_font_scale(2.0)
  tp.draw()
  let hp2 = tp.get(Button, label="android-misc.drive.player.speed").rect.3
  assert_true(hp2 >= phone_key_side, msg="phone 2.0x speed height: \{hp2}")
  assert_eq(tp.fixed_outgrown(), [], msg="phone 2.0x fixed_outgrown")
  assert_eq(tp.squeeze_faults(), [], msg="phone 2.0x squeeze_faults")
  tp.set_font_scale(3.0)
  tp.draw()
  let hp3 = tp.get(Button, label="android-misc.drive.player.speed").rect.3
  assert_true(hp3 > phone_key_side, msg="phone 3.0x speed height grew: \{hp3}")
  assert_eq(tp.fixed_outgrown().filter(fn(f) { f.contains("1×") }), [], msg="phone 3.0x speed fixed_outgrown")
  assert_eq(tp.squeeze_faults().filter(fn(f) { f.contains("1×") }), [], msg="phone 3.0x speed squeeze_faults")
}
