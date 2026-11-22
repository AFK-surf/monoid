// The file viewers on a desktop (the library's viewer_bar.mbt, reader.mbt): over the wide frame's whole
// window, as the desktop app's.

///|
/// The fixture's `mode` in a desktop's window: a chat's file open in its preview (chat-preview-…), a drive's text read
/// (reader…), seen once it is in.
fn desk_tester(
  mode : String,
  platform? : Int = 0,
  window_corner? : Double = 0.0,
  window_inset? : Bool = false,
) -> @ui.Tester {
  new_run()
  let src = fixture(mode)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform~, window_corner~, window_inset~)
  if mode.has_prefix("chat-preview") {
    open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  }
  t.draw()
  if mode.has_prefix("reader") || mode.has_prefix("player") {
    // (what the mode opens: 文档 and the file in it)
    app.nav.replace(Home)
    open_drive_fixture(mode)
    t.run_for(@ui.move_most_ms)
  } else {
    t.run_for(@ui.move_most_ms)
  }
  t
}

///|
/// Where a tool of the bar is, by how many from its end (download 0): the last at the window's corner as a page's bar's
/// last is (window_end_in), 32 each, 2 apart.
fn desk_tool_x(from_end : Int) -> Double {
  1280.0 - @sf.window_end_in(12.0) - 16.0 - from_end.to_double() * 34.0
}

///|
test "desk: an image on the canvas under the bar, back to its chat by name, which of two, its size and kind, no zoom's tools in it (zoomed by the hand and the keys); → steps, Esc closes" {
  let t = desk_tester("chat-preview-step")
  assert_true(@sfdesk.is_wide(t.ctx()))
  assert_true(t.find("界面草图.png") is Some(_))
  // (its size in pixels as its message says it)
  assert_true(t.find("1 / 2 · 18 KB · 图片 · 600×400") is Some(_))
  // no zoom's tools in the bar (−, its per cent, +, 1:1: the user, 2026-11-01), its close the way back (named by the chat)
  for k in ["web-main.preview.zoomOutKey", "web-main.preview.fitKey", "web-main.preview.zoomInKey", "web-main.preview.actualKey"] {
    assert_eq(t.all(Button, label=@sf.t(k)).length(), 0, msg="no zoom's tool in the bar: \{k}")
  }
  assert_true(t.find("100%") is None && t.find("1:1") is None, msg="no zoom's tool in the bar: its per cent, 1:1")
  assert_true(t.find_last("整理发布清单") is Some(_))
  // → the one after
  t.key(@ui.key_code_right)
  assert_eq(viewer.get().unwrap().file.name, "第二版.png")
  assert_true(t.find("2 / 2 · 21 KB · 图片 · 400×560") is Some(_))
  // Esc: gone at once, only drawn fading out
  t.key(@ui.key_escape)
  assert_true(viewer.get() is None)
  t.run_for(pv_fade_ms)
  assert_true(t.find("第二版.png") is None)
}

///|
test "desk: a chat's film says its size, length and rate in the bar as its message does, none of it read yet" {
  let t = desk_tester("chat-preview-video")
  assert_true(t.find("1280×720 · 0:13 · 30 fps") is Some(_))
}

///|
test "desk: a chat's film fitted clear of the bar and the controls, never under them; ⌘ and the wheel zoom it" {
  let t = desk_tester("chat-preview-video")
  let key = viewer.get().unwrap().media.unwrap().key()
  let (top, foot) = @sf.player_room(1280.0)
  let (_, y, w, h) = @sf.player_picture_at(key).unwrap()
  // 1280 × 720 in 1280 × (800 less the bar and the controls): as tall as that leaves, under the bar, over the controls
  assert_true((y - top).abs() < 0.5, msg="\{y} \{top}")
  assert_true((y + h - (800.0 - foot)).abs() < 0.5, msg="\{y + h} \{800.0 - foot}")
  assert_true(w < 1280.0, msg="\{w}")
  t.wheel_with(640.0, 400.0, 0.0, -200.0, @ui.wheel_mod_cmd)
  t.run_for(@ui.move_most_ms)
  let (_, _, w2, _) = @sf.player_picture_at(key).unwrap()
  assert_true(w2 > w * 1.3, msg="\{w} \{w2}")
}

///|
test "desk: Esc closes a chat's film as it flies in, before its player is up" {
  new_run()
  let src = fixture("chat-preview-video")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  t.draw()
  t.run_for(@ui.move_most_ms / 4.0)
  assert_true(viewer.get() is Some(_))
  t.key(@ui.key_escape)
  assert_true(viewer.get() is None)
}

///|
test "desk: a click on the image closes the preview once a second would have come, two zoom it; one round it closes it at once" {
  let t = desk_tester("chat-preview-image")
  let v = viewer.get().unwrap()
  // left alone, the bar stays
  t.run_for(left_alone_ms)
  assert_true(v.bars_shown())
  // 600 × 400 in 1280 × 800, fitted 32 in: in the middle as it is; two clicks zoom it, open still
  t.tap(640.0, 400.0)
  t.tap(640.0, 400.0)
  t.run_for(@ui.double_click_ms)
  assert_true(viewer.get() is Some(_))
  assert_true(v.zoom.zoomed_at(t.time()))
  assert_true(v.bars_shown())
  // one click on it: closed once a second would have come, not before
  t.tap(640.0, 400.0)
  t.run_for(@ui.double_click_ms / 2.0)
  assert_true(viewer.get() is Some(_))
  t.run_for(@ui.double_click_ms)
  assert_true(viewer.get() is None)
  // opened again, a click round it closes it at once
  let t = desk_tester("chat-preview-image")
  t.tap(150.0, 700.0)
  assert_true(viewer.get() is None)
}

///|
test "desk: the bar hidden by a click shows while the pointer is along the top, where it is, and hides again past it" {
  let t = desk_tester("chat-preview-image")
  let v = viewer.get().unwrap()
  // (an image's click closes it: its bars hidden as a click on another kind hides them)
  v.toggle()
  t.draw()
  assert_true(!v.bars_shown())
  t.move_to(640.0, 20.0)
  t.draw()
  assert_true(v.bars_shown())
  t.move_to(640.0, 400.0)
  t.draw()
  assert_true(!v.bars_shown())
}

///|
test "desk: ⌘ and the wheel (or a pinch) zoom round the pointer, the wheel alone pans; + − 0 1 as the web's keys" {
  let t = desk_tester("chat-preview-image")
  let z = viewer.get().unwrap().zoom
  // (how big it is shown now, as the picture is drawn: its glide's way read at the moment, not a field)
  let shown = fn() { z.scale_at(t.time()) }
  // 600 × 400 fitted in 1280 × 800: as it is
  assert_true((shown() - 1.0).abs() < 0.001)
  // fitted, the wheel alone moves nothing
  t.wheel_with(640.0, 400.0, 0.0, 120.0, 0)
  assert_true((shown() - 1.0).abs() < 0.001)
  // ⌘ and the wheel up: e^(200 × 0.002)
  t.wheel_with(640.0, 400.0, 0.0, -200.0, @ui.wheel_mod_cmd)
  assert_true((shown() - @dmath.exp(0.4)).abs() < 0.01, msg="\{shown()}")
  // a pinch (a wheel with ⌃, marked so): its small steps finer
  t.wheel_with(640.0, 400.0, 0.0, -10.0, @ui.wheel_mod_ctrl | @ui.wheel_mod_pinch)
  assert_true((shown() - @dmath.exp(0.4) * @dmath.exp(0.1)).abs() < 0.01, msg="\{shown()}")
  // 0 fitted again, + a quarter more (its glide run), 1 as it is
  t.key(@ui.key_of_char('0'))
  t.run_for(@ui.move_most_ms)
  assert_true((shown() - 1.0).abs() < 0.001, msg="\{shown()}")
  t.key(@ui.key_of_char('='))
  t.run_for(@ui.move_most_ms)
  assert_true((shown() - 1.25).abs() < 0.01, msg="\{shown()}")
  t.key(@ui.key_of_char('1'))
  t.run_for(@ui.move_most_ms)
  assert_true((shown() - 1.0).abs() < 0.01, msg="\{shown()}")
}

///|
test "desk: a file told of says so, 下载 the page's button; the bar's own download too" {
  let t = desk_tester("chat-preview-none")
  assert_true(t.find("此文件类型不支持预览") is Some(_))
  // (its kind on its card, its size under its name)
  assert_true(t.find("BIN") is Some(_) && t.find("4 KB") is Some(_))
  t.tap_text("下载")
  t.frame()
  // downloaded by the core: how far, in the button's place
  assert_true(t.find("正在下载 0% · 4 KB") is Some(_))
}

///|
test "desk: a chat's Markdown reads in the reader on its paper, the preview's own bar not drawn; Esc closes it" {
  let t = desk_tester("chat-preview-md")
  t.run_for(@sf.reader_place_ms)
  // its words as a document's, its bar the reader's (no 预览 / 源码)
  assert_true(t.find("发布前要做的") is Some(_))
  assert_true(t.find("说明.md") is Some(_))
  assert_true(t.find("源码") is None)
  t.key(@ui.key_escape)
  assert_true(viewer.get() is None)
}

///|
test "desk: words picked in a chat's Markdown read over its chat, the pointer taken to where the chat's words lie under the paper: the file's alone, none of the chat's" {
  let t = desk_tester("chat-preview-md")
  t.run_for(@sf.reader_place_ms)
  // (a message of the chat under the reader's paper, over the list's first line)
  let (_, uy, _, uh) = t.run_rects("截图也一起换掉")[0]
  let (x, y, _, h) = t.run_rects("换成")[0]
  assert_true(uy + uh / 2.0 < y, msg="the chat's words under the paper above the line pressed")
  // (taken to the start of the file's first item, over the line pressed, wherever the chat's page has its messages
  // under the paper: the chat's own of those words are under it, not drawn)
  let firsts = t.run_rects("版本号和更新说明").filter(fn(r) { r.1 < y })
  assert_true(firsts.length() > 0, msg="the file's first item over the line pressed")
  let (fx, fy, _, fh) = firsts[0]
  t.drag(x + 1.0, y + h / 2.0, fx + 1.0, fy + fh / 2.0)
  let picked = t.ctx().selected_text()
  assert_true(picked.contains("版本号和更新说明"), msg=picked)
  assert_false(picked.contains("换掉"), msg=picked)
}

///|
test "desk: a drive's text over the whole window, back to its folder; 目录 docks at the right, Esc shuts it, then goes back" {
  let t = desk_tester("reader")
  t.run_for(@sf.reader_place_ms)
  assert_true(app.nav.top() is DriveRead(_))
  assert_true(t.find("长篇小说.txt") is Some(_))
  // over the sidebar: a press where its rows are is the reader's
  t.tap(140.0, 200.0)
  assert_true(app.nav.top() is DriveRead(_))
  // 目录, the first of its four tools
  t.tap(desk_tool_x(3), 22.0)
  let r = @sf.reading_for(reader_key({ station: "ws1/st1", root: Some(fix_docs), path: "长篇小说.txt" }))
  assert_true(r.panel.get() == @sf.ReaderPanel::Contents)
  assert_true(t.find("在全文中搜索") is Some(_))
  t.key(@ui.key_escape)
  assert_true(r.panel.get() == @sf.ReaderPanel::NoPanel)
  t.key(@ui.key_escape)
  assert_false(app.nav.top() is DriveRead(_))
}

///|
test "desk: a trackpad's two fingers going down a picture take it down; stopped short it goes back, far enough it closes; a mouse's wheel takes it nowhere" {
  let t = desk_tester("chat-preview-image")
  let v = viewer.get().unwrap()
  // (the fingers going down: the wheel says the page under them goes up)
  t.wheel(640.0, 400.0, -20.0)
  t.run_for(@ui.input_step_ms)
  t.wheel(640.0, 400.0, -20.0)
  t.run_for(@ui.input_step_ms)
  assert_true(v.zoom.pulled_at(t.time()) > 0.0, msg="taken down")
  assert_true(viewer.get() is Some(_), msg="a short way: open")
  t.run_for(@sfbase.wheel_rest_ms + @ui.move_most_ms)
  assert_eq(v.zoom.pulled_at(t.time()), 0.0, msg="stopped short: back")
  assert_true(viewer.get() is Some(_), msg="stopped short: open")
  t.wheel(640.0, 400.0, -50.0)
  t.run_for(@ui.input_step_ms)
  t.wheel(640.0, 400.0, -50.0)
  assert_true(viewer.get() is None, msg="far enough down: closed")
  // (a mouse's notches, a browser's in points or the system's: nothing)
  let t = desk_tester("chat-preview-image")
  let v = viewer.get().unwrap()
  t.wheel(640.0, 400.0, -100.0)
  t.wheel_phase(640.0, 400.0, -40.0, 4)
  t.draw()
  assert_eq(v.zoom.pulled_at(t.time()), 0.0, msg="a mouse's wheel: not taken down")
  t.run_for(@ui.move_most_ms)
  assert_true(viewer.get() is Some(_), msg="a mouse's wheel: open")
}

///|
test "desk: a drive's text read on by the wheel: its place on, the bar gone up as it is read on down" {
  let t = desk_tester("reader")
  t.run_for(@sf.reader_place_ms)
  let r = @sf.reading_for(reader_key({ station: "ws1/st1", root: Some(fix_docs), path: "长篇小说.txt" }))
  let was = r.place.get()
  t.wheel(640.0, 400.0, 900.0)
  t.run_for(@ui.move_most_ms)
  assert_true(r.place.get() != was, msg="read on from \{Repr(was)}: \{Repr(r.place.get())}")
  assert_true(r.bar_hidden.get(), msg="the bar gone up")
}

///|
/// Open the 3-image chain (对照草图.png -> 界面草图.png -> 第二版.png) on a 1280x800 desktop window, using compact
/// 16x16 PNGs so 3-image simultaneous decodes stay well within the file's host_image_bytes bar.
fn desk_viewer_three() -> @ui.Tester {
  new_run()
  let base = fixture("chat")
  let tiny = @sffixture.fixture_png(16, 16)
  let src : Source = {
    ..base,
    read_going: fn(name, params, on_value, done) {
      if name == "station.file" {
        done(Ok(({ "contentType": "image/png" }, tiny)))
      } else {
        (base.read_going)(name, params, on_value, done)
      }
    },
  }
  let first = preview_files().iter().find_first(fn(f) { f.0.name == "对照草图.png" }).unwrap().0
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  open_preview("ws1/st1", "s-c1", first, beside=false, steps=InChat(Some(1.0), "s-c1"))
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "desk viewer: horizontal trackpad swipe flips next and previous when past threshold, snaps back when short" {
  let t = desk_tester("chat-preview-step")
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png")
  // Short swipe left (total 36pt slow): follows strip, does not flip, snaps back after wheel_rest_ms.
  for _ in 0..<6 {
    t.advance(@ui.input_step_ms)
    t.wheel_with(640.0, 400.0, 6.0, 0.0, 0)
  }
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png", msg="short swipe stays on first image")
  assert_true(pv_strip.way.value_at(t.time()) < -10.0, msg="strip followed fingers left")
  t.run_for(@sfbase.wheel_rest_ms + @ui.move_most_ms)
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png", msg="still on first image after snap-back")
  assert_true(pv_strip.way.value_at(t.time()).abs() < 0.5, msg="strip snapped back to 0")
  // Full swipe left past threshold -> flips to 第二版.png.
  for _ in 0..<8 {
    t.advance(@ui.input_step_ms)
    t.wheel_with(640.0, 400.0, 18.0, 0.0, 0)
  }
  assert_eq(viewer.get().unwrap().file.name, "第二版.png", msg="swipe left flips to next image")
  t.run_for(@sfbase.wheel_rest_ms + @ui.move_most_ms)
  // Full swipe right past threshold -> flips back to 界面草图.png.
  for _ in 0..<8 {
    t.advance(@ui.input_step_ms)
    t.wheel_with(640.0, 400.0, -18.0, 0.0, 0)
  }
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png", msg="swipe right flips back to previous image")
}

///|
test "desk viewer: one horizontal swipe with long momentum tail flips only once on a 3-image chain" {
  let t = desk_viewer_three()
  assert_eq(viewer.get().unwrap().file.name, "对照草图.png")
  // Finger swipe left (phase 1) past threshold -> flips to 界面草图.png.
  for _ in 0..<6 {
    t.advance(@ui.input_step_ms)
    t.wheel_phase(640.0, 400.0, 0.0, 1, dx=22.0)
  }
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png", msg="flipped once to middle image")
  // Long decaying momentum tail (phase 3) totaling > 200pt must be eaten, not flip to 第二版.png.
  for d in [20.0, 18.0, 16.0, 15.0, 14.0, 13.0, 12.0, 11.0, 10.0, 9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0] {
    t.advance(@ui.input_step_ms)
    t.wheel_phase(640.0, 400.0, 0.0, 3, dx=d)
  }
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png", msg="momentum tail must not flip a second image")
  t.run_for(@sfbase.wheel_rest_ms + @ui.move_most_ms)
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png", msg="settled on middle image")
}

///|
test "desk viewer: consecutive second swipe during momentum flips again (native phase host)" {
  let t = desk_viewer_three()
  assert_eq(viewer.get().unwrap().file.name, "对照草图.png")
  // First swipe (phase 1 -> flips to 界面草图.png) + partial momentum (phase 3).
  for _ in 0..<6 {
    t.advance(@ui.input_step_ms)
    t.wheel_phase(640.0, 400.0, 0.0, 1, dx=22.0)
  }
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png", msg="first swipe flipped to second image")
  for d in [16.0, 12.0, 8.0] {
    t.advance(@ui.input_step_ms)
    t.wheel_phase(640.0, 400.0, 0.0, 3, dx=d)
  }
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png", msg="momentum stays on second image")
  // Immediately start second swipe (phase 1) with no wheel_rest_ms pause -> flips to 第二版.png.
  for _ in 0..<6 {
    t.advance(@ui.input_step_ms)
    t.wheel_phase(640.0, 400.0, 0.0, 1, dx=22.0)
  }
  assert_eq(viewer.get().unwrap().file.name, "第二版.png", msg="second swipe during momentum flips to third image")
}

///|
test "desk viewer: consecutive second swipe during momentum flips again (phase-0 web host)" {
  let t = desk_viewer_three()
  assert_eq(viewer.get().unwrap().file.name, "对照草图.png")
  // First swipe (phase 0) -> flips to 界面草图.png.
  for _ in 0..<6 {
    t.advance(@ui.input_step_ms)
    t.wheel_with(640.0, 400.0, 22.0, 0.0, 0)
  }
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png", msg="first phase-0 swipe flipped")
  // Momentum decays down to 4pt with no pause.
  for d in [16.0, 12.0, 8.0, 5.0, 4.0] {
    t.advance(@ui.input_step_ms)
    t.wheel_with(640.0, 400.0, d, 0.0, 0)
  }
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png", msg="decaying phase-0 tail eaten")
  // Second swipe rebounds |dx| back to 22pt without pause -> flips to 第二版.png.
  for _ in 0..<6 {
    t.advance(@ui.input_step_ms)
    t.wheel_with(640.0, 400.0, 22.0, 0.0, 0)
  }
  assert_eq(viewer.get().unwrap().file.name, "第二版.png", msg="second phase-0 swipe after rebound flips to third image")
}

///|
test "desk viewer: boundary swipe past first/last image resists at 1/3 and snaps back without flipping" {
  let t = desk_tester("chat-preview-step")
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png")
  // At first image (no before): swipe right resists at 1/3 and snaps back.
  for _ in 0..<6 {
    t.advance(@ui.input_step_ms)
    t.wheel_with(640.0, 400.0, -30.0, 0.0, 0)
  }
  let s = pv_strip.way.value_at(t.time())
  assert_true(s > 0.0 && s < 70.0, msg="edge drag damped to ~1/3 (expected ~60): \{s}")
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png", msg="cannot flip before first image")
  t.run_for(@sfbase.wheel_rest_ms + @ui.move_most_ms)
  assert_true(pv_strip.way.value_at(t.time()).abs() < 0.5, msg="edge drag snapped back to 0")
  // Single-image viewer (NoSteps): both directions resist at 1/3 and snap back.
  let t1 = desk_tester("chat-preview-image")
  for _ in 0..<6 {
    t1.advance(@ui.input_step_ms)
    t1.wheel_with(640.0, 400.0, 30.0, 0.0, 0)
  }
  let s1 = pv_strip.way.value_at(t1.time())
  assert_true(s1 < 0.0 && s1 > -70.0, msg="single-image drag damped to ~-60: \{s1}")
  t1.run_for(@sfbase.wheel_rest_ms + @ui.move_most_ms)
  assert_true(pv_strip.way.value_at(t1.time()).abs() < 0.5, msg="single-image drag snapped back")
}

///|
test "desk viewer: horizontal paging preserves zoomed pan, mouse wheel notch, modifier keys, and vertical pull-to-close" {
  // 1. Mouse wheel notch (phase 4) and browser horizontal notch (120) do not page.
  let t = desk_tester("chat-preview-step")
  t.wheel_phase(640.0, 400.0, 0.0, 4, dx=120.0)
  t.wheel_with(640.0, 400.0, 120.0, 0.0, 0)
  t.draw()
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png", msg="mouse notch does not page")
  assert_eq(pv_strip.way.value_at(t.time()), 0.0, msg="mouse notch does not move strip")
  // 2. Modifier key held (Cmd/Shift) does not page.
  t.wheel_with(640.0, 400.0, 60.0, 0.0, @ui.wheel_mod_cmd)
  t.wheel_with(640.0, 400.0, 60.0, 0.0, @ui.wheel_mod_shift)
  t.draw()
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png", msg="modifier wheel does not page")
  // 3. Zoomed in past window width: horizontal wheel pans the image instead of paging.
  t.wheel_with(640.0, 400.0, 0.0, -600.0, @ui.wheel_mod_cmd)
  t.run_for(@ui.move_most_ms)
  let v = viewer.get().unwrap()
  assert_true(v.zoom.zoomed_at(t.time()), msg="zoomed in")
  let before_rect = v.zoom.rect_at(t.time()).unwrap()
  for _ in 0..<6 {
    t.advance(@ui.input_step_ms)
    t.wheel_with(640.0, 400.0, 25.0, 0.0, 0)
  }
  assert_eq(viewer.get().unwrap().file.name, "界面草图.png", msg="zoomed horizontal wheel does not page")
  let after_rect = v.zoom.rect_at(t.time()).unwrap()
  assert_true(after_rect.0 < before_rect.0, msg="zoomed horizontal wheel pans image")
  // 4. Vertical pull-to-close still closes fitted image even when multi-image stepping is available.
  let t2 = desk_tester("chat-preview-step")
  t2.wheel(640.0, 400.0, -60.0)
  t2.run_for(@ui.input_step_ms)
  t2.wheel(640.0, 400.0, -60.0)
  assert_true(viewer.get() is None, msg="vertical pull-to-close still works")
}
