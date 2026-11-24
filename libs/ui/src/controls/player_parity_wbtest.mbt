// The one player as the old view draws it (player.mbt's `player`, a drive's) and as nodes of the window's tree
// (player_node.mbt's `player_node`, a chat's viewer's), given the same file and the same inputs: each step said of
// both the same (what it told its host, what it says, its controls), a single file's (no folder's others, no subtitle
// beside it: those are the drive's alone, player_node has none, its head says why).
//
// Not here, and why: the drive's folder (選集, the next one counted down) and the subtitle beside a film are the old
// player's alone (player_node plays one chat's file, `beside` none); the controls going of themselves after
// media_rest_ms is no one's (the user, 2026-10-28: there till a tap hides them, player.mbt's new_media rest_ms 0),
// held below as the same for both.

///|
/// One of the two players of film `name` (`kind`, `facts`), a phone's (`narrow`) or a desktop's, `window` (its width,
/// height and platform) where given: the old view's (`node` false) or the window's tree's; its way back counted in
/// `backs`; its player, to pin.
fn either_player(
  node : Bool,
  narrow : Bool,
  name : String,
  backs : Array[Int],
  kind? : String = "video",
  facts? : FileFacts = no_facts,
  window? : (Double, Double, Int),
  finish? : Bool = true,
) -> (@ui.Tester, @player.Media) {
  if !node {
    let t = player_tester(narrow, name, [], [], backs, kind~, facts~, window?)
    return (t, playing_for("k").media)
  }
  let (w, h, platform) = window.unwrap_or(if narrow { (390.0, 844.0, 1) } else { (1280.0, 800.0, 0) })
  set_viewer_host(viewer_host_default())
  set_words(fn(key, args) {
    args.fold(init=test_words.get(key).unwrap_or(key), fn(said, a) { said.replace_all(old="{" + a.0 + "}", new=a.1) })
  })
  let file = film(name, kind~, facts~)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h~, platform~, finish~)
  // (opened as a chat's viewer opens it, once there is a host to tell: Viewer::fetch)
  let m = new_media("parity-node")
  m.open({ name, mime: file.mime, audio: kind == "audio", read: player_read(file), direct: "" })
  @ui.set_view_app(fn(root) {
    root.keymap(Is(@view.Keymap::new(player_bindings()))) |> ignore
    root.box(fn(v) {
      v.grow(Is(1.0)) |> ignore
      player_node(
        v,
        m,
        file,
        fn() { v.window() },
        back_label=fn() { "影片" },
        on_back=fn() { backs.push(1) },
        still=fn() { "" },
        flying=fn() { false },
        going=fn() { false },
        move_beside=fn() { None },
      )
      |> ignore
    })
    |> ignore
  })
  (t, m)
}

///|
/// What step `step` does on both players, each made as `made` says: what each comes to (`seen`), the same for both.
fn[T : Eq + Debug] both(
  what : String,
  made : (Bool) -> (@ui.Tester, @player.Media),
  step : (@ui.Tester, @player.Media) -> T raise,
) -> T raise {
  let prev = words_of.val
  let (t, m) = made(false)
  let old = step(t, m)
  let (t, m) = made(true)
  let new = step(t, m)
  set_words(prev)
  assert_true(new == old, msg="\{what}: the window's tree's player \{Repr(new)}, the old one's \{Repr(old)}")
  new
}

///|
test "both players, a phone's: opened, played; the film edge to edge in the middle, on black" {
  let seen = both("opened", fn(node) { either_player(node, true, "a.mp4", []) }, fn(t, _) {
    t.draw()
    t.run_for(@ui.move_most_ms)
    let holes = t.holes()
    let hole = if holes.length() == 1 {
      let (_, y, w, h) = holes[0]
      ((w * 10.0).round(), (h * 10.0).round(), (y * 10.0).round())
    } else {
      (-1.0, -1.0, -1.0)
    }
    (told(t, 1), hole)
  })
  assert_true(seen.0 && (seen.1).0 == 3900.0, msg="\{Repr(seen)}")
}

///|
test "both players, a phone's and a desktop's: played, left alone past idle deadline, controls auto-fade" {
  for narrow in [true, false] {
    let seen = both("left alone", fn(node) { either_player(node, narrow, "a.mp4", []) }, fn(t, m) {
      if !narrow {
        t.host_says_finger(Some(false))
      }
      m.pin({ ..pinned(1000.0), playing: true })
      t.draw()
      let idle_ms = if narrow { player_touch_idle_ms } else { player_desk_idle_ms }
      t.run_for(idle_ms + @player.media_sleep_ms + 50.0)
      t.query(Slider, label="web-pages.drive.player.position") is None
    })
    assert_true(seen, msg="narrow \{narrow}: controls auto-faded")
  }
}

///|
test "both players, a phone's: paused, its controls step a frame on, to that frame's time" {
  both("a frame on", fn(node) { either_player(node, true, "a.mp4", []) }, fn(t, _) {
    t.draw()
    t.run_for(@ui.move_most_ms)
    let on = t.locate("icon:chevron-right")
    guard on.length() > 0 else { return false }
    let (x, y) = on[0]
    t.tap(x, y)
    t.draw()
    told(t, 3, value="16.6")
  })
  |> ignore
}

///|
test "both players, a phone's: held still it plays at 2× until let go, then as it was" {
  let seen = both("held", fn(node) { either_player(node, true, "a.mp4", []) }, fn(t, m) {
    m.pin(pinned(1000.0))
    t.draw()
    t.press_at(195.0, 300.0)
    t.run_for(@ui.long_press_ms)
    let held = (t.find("2× 播放中") is Some(_), told(t, 4, value="2"))
    t.release(195.0, 300.0)
    t.draw()
    (held, t.find("2× 播放中") is Some(_), told(t, 4, value="1"))
  })
  assert_eq(seen, ((true, true), false, true))
}

///|
test "both players, a phone's: a finger down the film takes it away with it; one along it moves through the time" {
  let seen = both("dragged", fn(node) { either_player(node, true, "a.mp4", []) }, fn(t, _) {
    t.draw()
    t.drag(100.0, 300.0, 300.0, 300.0)
    told(t, 3)
  })
  assert_true(seen)
  let backs : Array[Int] = []
  let backs_new : Array[Int] = []
  let (t, _) = either_player(false, true, "a.mp4", backs)
  t.draw()
  t.drag(195.0, 300.0, 195.0, 500.0)
  let (u, _) = either_player(true, true, "a.mp4", backs_new)
  u.draw()
  u.drag(195.0, 300.0, 195.0, 500.0)
  u.run_for(@ui.move_most_ms)
  assert_eq(backs_new.length(), backs.length())
}

///|
test "both players, a phone's: a finger's shake as it taps (5 across, 5 down) no drag: no seek, no pause" {
  both("a shaking tap", fn(node) { either_player(node, true, "a.mp4", []) }, fn(t, _) {
    t.draw()
    let before = t.views().length()
    t.drag(195.0, 300.0, 200.0, 305.0)
    t.draw()
    t.views()[before:].iter().any(fn(l) { l.contains(" 3 ") || l.contains(" 9 ") || l.contains(" 11 ") })
  })
  |> ignore
}

///|
test "both players, a desktop's: a pointer click immediately plays or pauses once; double click swallows second Up" {
  let seen = both("double clicked", fn(node) { either_player(node, false, "a.mp4", []) }, fn(t, _) {
    t.host_says_finger(Some(false))
    t.draw()
    let plays = fn() {
      t.views().filter(fn(s) {
        let w = s.split(" ").to_array()
        w.length() > 2 && w[0] == "control" && (w[2] == "1" || w[2] == "2")
      }).length()
    }
    let before = plays()
    t.tap(640.0, 400.0)
    let one = plays() - before
    t.advance(@ui.double_tap_ms / 2.0)
    t.tap(640.0, 400.0)
    t.draw()
    (one, plays() - before)
  })
  assert_eq(seen, (1, 1))
}

///|
test "both players, a desktop's: its speeds a menu, 0.25× picked" {
  let seen = both("speeds", fn(node) { either_player(node, false, "a.mp4", []) }, fn(tt, _) raise {
    tt.draw()
    tt.click(Button, label=t("web-pages.drive.player.rate"))
    tt.run_for(@ui.move_most_ms)
    let shown = tt.find("0.25×") is Some(_)
    tt.tap_text("0.25×")
    tt.draw()
    (shown, told(tt, 4, value="0.25"))
  })
  assert_eq(seen, (true, true))
}

///|
test "both players, a desktop's: the bar says the film's size, length and rate as its message does, before the host has read them" {
  let facts : FileFacts = { width: 1280.0, height: 720.0, duration: 12500.0, frames: 375 }
  let seen = both("its facts", fn(node) { either_player(node, false, "a.mp4", [], facts~) }, fn(t, _) {
    t.draw()
    t.run_for(@ui.move_most_ms)
    t.find("1280×720 · 0:13 · 30 fps") is Some(_)
  })
  assert_true(seen)
}

///|
test "both players, a desktop's: at its end, its host still saying it plays, its play key plays it from its start" {
  let seen = both("at its end", fn(node) { either_player(node, false, "a.mp4", []) }, fn(tt, _) raise {
    tt.draw()
    tt.set_player(1, position=10000.0, duration=10000.0, playing=true, ended=true)
    tt.draw()
    tt.run_for(@ui.move_most_ms)
    let before = tt.views().length()
    tt.click(Button, label=t("web-main.video.playKey"))
    tt.draw()
    let told = tt.views()[before:].to_owned()
    (told.contains("control 1 3 0"), told.iter().any(fn(l) { l.has_prefix("control 1 2") }))
  })
  assert_eq(seen, (true, false))
}

///|
test "a player waiting for its first frame shows the action its play key will take" {
  let (tt, _) = either_player(true, false, "a.webm", [], finish=false)
  assert_true(tt.view_said("{\"info\":{\"view\":1,\"state\":0,\"at\":[13000,0,1,1280,900,1000,0,1,9000,0]}}"))
  tt.draw()
  tt.run_for(@ui.move_most_ms)
  let before = tt.views().length()
  tt.click(Button, label=t("web-main.video.pauseKey"))
  tt.draw()
  let told = tt.views()[before:].to_owned()
  assert_true(told.iter().any(fn(l) { l.has_prefix("control 1 2") }))
  assert_true(tt.view_said("{\"info\":{\"view\":1,\"state\":0,\"at\":[13000,0,0,1280,900,1000,0,0,9000,0]}}"))
  tt.draw()
  let before = tt.views().length()
  tt.click(Button, label=t("web-main.video.playKey"))
  tt.draw()
  let told = tt.views()[before:].to_owned()
  assert_true(told.iter().any(fn(l) { l.has_prefix("control 1 1") }))
  // A host may say it is waiting on bytes while its clock is not moving.
  assert_true(tt.view_said("{\"info\":{\"view\":1,\"state\":1,\"at\":[13000,2000,0,1280,900,1000,1,1,9000,0]}}"))
  tt.draw()
  let before = tt.views().length()
  tt.click(Button, label=t("web-main.video.pauseKey"))
  tt.draw()
  let told = tt.views()[before:].to_owned()
  assert_true(told.iter().any(fn(l) { l.has_prefix("control 1 2") }))
}

///|
test "both players, a desktop's on a narrow stage: its ⋯ lists the speeds only where its speed left the row" {
  let prev = words_of.val
  let kept = [0, 0]
  for node in [false, true] {
    for w in [600.0, 610.0, 620.0, 640.0, 680.0, 780.0] {
      let (tt, m) = either_player(node, false, "a.mp4", [], window=(w, 800.0, 0))
      // (paused at its start: 保存此帧 among its keys)
      m.pin({ ..pinned(1000.0), playing: false })
      tt.draw()
      tt.run_for(@ui.move_most_ms)
      let rate = t("web-pages.drive.player.rate")
      let more = t("web-main.menu.more")
      let in_row = tt.query(Button, label=rate) is Some(_)
      if tt.query(Button, label=more) is Some(_) {
        tt.click(Button, label=more) |> ignore
        tt.run_for(@ui.move_most_ms)
        let listed = tt.find("0.25×") is Some(_)
        assert_eq(listed, !in_row, msg="node \{node}, \{w} wide: its speed in its row \{in_row}, in its ⋯ \{listed}")
        if in_row {
          kept[if node { 1 } else { 0 }] += 1
        }
      }
    }
  }
  set_words(prev)
  // (a single file's player has none of a folder's keys: at none of these widths does 保存此帧 leave while the speed
  // stays, for either; where one does, its ⋯ lists no speeds, as asserted above)
  ignore(kept)
}
