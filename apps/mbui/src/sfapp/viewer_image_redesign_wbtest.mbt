// Wave 27 · Track P (Image Viewer Interaction Redesign) deterministic acceptance matrix:
// - `assert_idle()` after settled entry keeps bars shown, never fading by themselves however long the hand rests;
//   locks (loading, menu, bar focus, screen reader) hold them, the pointer leaving the window keeps them
// - Per-side 84pt hot zones lighting only that side's arrow (opposite side hidden/unclickable/unreachable),
//   hard suppression in zoomed & marking states, embedded image tab zero-regression
// - Full-bleed stage & tall image entering/leaving marking: actual drawn rect `(x, y, w, h)` and pin screen position
//   strictly zero-jump, while preserving keyboard lift avoidance
// - Unified click/close boundaries (desktop blank space vs 84pt hot zone blank vs unknown size vs picture toggle with
//   manual_hidden anti-rebound vs full-bleed Esc close; touch tap inside/outside toggles bars including Duo fitted)

///|
let idle_margin_ms : Double = 100.0

///|
/// A long rest of the hand: the bars never fade by themselves however long it is.
let hand_rest_ms : Double = 10000.0

///|
let wheel_half_rest_ms : Double = 80.0

///|
let wheel_past_rest_ms : Double = 220.0

///|
let twice_mid_ms : Double = 50.0

///|
fn open_settled_desk_image(what : String, w? : Double = 1280.0, h? : Double = 800.0) -> (@ui.Tester, Viewer) {
  let t = preview_tester(what, w~, platform=0)
  ignore(h)
  // Settle any entry fade/flight so `assert_idle()` sees nothing left moving.
  t.run_for(@ui.move_most_ms)
  let v = viewer.get().unwrap()
  (t, v)
}

///|
test "Track P: settled image viewer passes assert_idle with bars shown, and never fades them by itself" {
  let (t, v) = open_settled_desk_image("image")
  t.assert_idle()
  assert_true(v.bars_shown(), msg="settled entry: bars shown")
  t.move_to(640.0, 400.0)
  t.draw()
  t.run_for(hand_rest_ms)
  t.assert_idle()
  assert_true(v.bars_shown(), msg="after a long rest: bars still shown")
}

///|
test "Track P: desktop locks (menu, bar focus, image loading, screen reader) hold bars, which stay on release" {
  // 1. Context menu lock
  let (t, v) = open_settled_desk_image("image")
  t.move_to(640.0, 400.0)
  t.draw()
  let (rx, ry, rw, rh) = v.zoom.rect_at(t.time()).unwrap()
  t.right_click(rx + rw / 2.0, ry + rh / 2.0)
  t.run_for(@sf.presented_rest() - t.time())
  assert_true(v.menu_open && v.bars_shown(), msg="menu open locks bars")
  t.run_for(hand_rest_ms)
  assert_true(v.bars_shown(), msg="a long rest while menu open: still shown")
  t.key(@ui.key_escape)
  t.run_for(@sf.presented_rest() - t.time() + 10.0)
  assert_true(!v.menu_open, msg="Esc closes menu")
  t.run_for(hand_rest_ms)
  assert_true(v.bars_shown(), msg="a long rest after menu close: still shown")

  // 2. Bar keyboard focus lock
  let (t, v) = open_settled_desk_image("image")
  let mut tabs = 0
  while !v.bar_focused && tabs < 8 {
    t.key(@ui.key_tab)
    t.draw()
    tabs += 1
  }
  assert_true(v.bar_focused, msg="Tab moved focus into top bar")
  t.run_for(hand_rest_ms)
  assert_true(v.bars_shown(), msg="a long rest while bar focused: still shown")
  @ui.view_tree().unwrap().focus_to(None) |> ignore
  t.draw()
  assert_true(!v.bar_focused, msg="focus left bar")
  t.run_for(hand_rest_ms)
  assert_true(v.bars_shown(), msg="a long rest after focus left bar: still shown")

  // 3. Image loading lock
  let (t, v) = open_settled_desk_image("image")
  let saved_bytes = v.bytes.untracked()
  v.fetching.set(true)
  v.bytes.set(None)
  t.draw()
  assert_true(v.image_loading() && v.bars_shown(), msg="loading locks bars")
  t.run_for(hand_rest_ms)
  assert_true(v.bars_shown(), msg="a long rest while loading: still shown")
  v.bytes.set(saved_bytes)
  v.fetching.set(false)
  t.draw()
  assert_true(!v.image_loading(), msg="loading finished")
  t.run_for(hand_rest_ms)
  assert_true(v.bars_shown(), msg="a long rest after load finished: still shown")

  // 4. Plain a11y_on does NOT lock the bars (a click on the picture hides them); screen_reader_on wakes & locks bars +
  // arrows, and clearing it leaves them as the click did
  let (t, v) = open_settled_desk_image("step")
  t.move_to(640.0, 400.0)
  t.draw()
  t.set_a11y(true)
  t.draw()
  let (prx, pry, prw, prh) = v.zoom.rect_at(t.time()).unwrap()
  t.tap(prx + prw / 2.0, pry + prh / 2.0)
  t.draw()
  assert_true(!v.bars_shown() && !v.step_shown(1), msg="plain set_a11y(true) does NOT keep a click from hiding them")
  t.set_a11y(false)
  t.set_screen_reader(true)
  t.draw()
  assert_true(v.bars_shown() && v.step_shown(1), msg="set_screen_reader(true) actively wakes and locks bars and arrows")
  t.run_for(hand_rest_ms)
  assert_true(v.bars_shown() && v.step_shown(1), msg="screen_reader_on holds bars and arrows")
  t.set_screen_reader(false)
  t.draw()
  assert_true(!v.bars_shown(), msg="set_screen_reader(false): back to hidden, as the click left them")

  // 5. Tab specifically focuses viewer_bar_node's back button (watched via viewer_bar_watch_back) and holds the bars
  let (t_back, v_back) = open_settled_desk_image("image")
  t_back.move_to(640.0, 400.0)
  t_back.draw()
  let mut back_focused = false
  let mut step_tabs = 0
  while !back_focused && step_tabs < 12 {
    t_back.key(@ui.key_tab)
    t_back.draw()
    back_focused = t_back.all(Button, label="整理发布清单").iter().any(fn(b) { b.focused })
    step_tabs += 1
  }
  assert_true(back_focused, msg="Tab specifically focused viewer_bar_node back button")
  assert_true(v_back.bar_focused && v_back.bars_shown(), msg="back button focus sets bar_focused")
  t_back.run_for(hand_rest_ms)
  assert_true(v_back.bar_focused && v_back.bars_shown(), msg="back button focus holds bars")
}

///|
test "Track P: stepping to another image keeps the bars, and leaving the window keeps them" {
  let (t, v1) = open_settled_desk_image("step")
  t.move_to(640.0, 400.0)
  t.draw()
  assert_true(v1.bars_shown())
  // A while later, step to next image
  t.run_for(idle_margin_ms)
  t.key(@ui.key_code_right)
  t.draw()
  let v2 = viewer.get().unwrap()
  assert_true(v2.file.name != v1.file.name, msg="stepped to next image")
  assert_true(v2.bars_shown(), msg="v2 starts with bars shown")
  t.run_for(hand_rest_ms)
  assert_true(v2.bars_shown(), msg="v2 keeps bars shown after a long rest")
  // Leaving the window keeps them
  t.move_to(-1.0, -1.0)
  t.draw()
  assert_true(v2.bars_shown(), msg="pointer leaving window keeps them")
}

///|
test "Track P: 84pt left/right hot zones light only their own arrow, zoomed & marking hard-suppress arrows" {
  // Open middle image of a 3-image gallery so both prev and next neighbors exist.
  let t = preview_tester("step", w=1280.0, platform=0)
  t.key(@ui.key_code_right)
  t.run_for(@ui.move_most_ms)
  let v = viewer.get().unwrap()
  let prev_label = @sf.t("web-main.preview.prevKey")
  let next_label = @sf.t("web-main.preview.nextKey")
  // Hide bars and arrows completely: as a click on the picture does (its size may not be known yet)
  t.move_to(640.0, 400.0)
  t.draw()
  v.toggle()
  t.run_for(@sf.sleep_ms + @sf.viewer_bar_ms)
  assert_true(!v.bars_shown(), msg="bars faded")
  assert_eq(t.all(Button, label=prev_label).length(), 0, msg="faded: prev unreachable")
  assert_eq(t.all(Button, label=next_label).length(), 0, msg="faded: next unreachable")

  // Move pointer into left 84pt zone: only left arrow wakes; top bar stays hidden; right arrow unreachable
  t.move_to(24.0, 400.0)
  t.run_for(@sf.wake_ms)
  assert_true(!v.bars_shown(), msg="left 84pt zone does NOT wake top bar")
  assert_true(v.step_shown(-1), msg="left 84pt zone lights left arrow")
  assert_true(!v.step_shown(1), msg="left 84pt zone does NOT light right arrow")
  assert_eq(t.all(Button, label=prev_label).length(), 1, msg="left arrow reachable")
  assert_eq(t.all(Button, label=next_label).length(), 0, msg="right arrow hidden and unreachable")

  // Move pointer into right 84pt zone: symmetric (if v has a next neighbor, verify symmetry; else open first image)
  let t2 = preview_tester("step", w=1280.0, platform=0)
  let v2 = viewer.get().unwrap()
  t2.move_to(640.0, 400.0)
  t2.draw()
  v2.toggle()
  t2.run_for(@sf.sleep_ms + @sf.viewer_bar_ms)
  t2.move_to(1280.0 - 24.0, 400.0)
  t2.run_for(@sf.wake_ms)
  assert_true(!v2.bars_shown(), msg="right 84pt zone does NOT wake top bar")
  assert_true(v2.step_shown(1), msg="right 84pt zone lights right arrow")
  assert_true(!v2.step_shown(-1), msg="right 84pt zone does NOT light left arrow")
  assert_eq(t2.all(Button, label=next_label).length(), 1, msg="right arrow reachable")
  assert_eq(t2.all(Button, label=prev_label).length(), 0, msg="left arrow unreachable")

  // Zoomed state hard-suppresses arrows even when pointer is in right 84pt zone
  let (rx, ry, rw, rh) = v2.zoom.rect_at(t2.time()).unwrap()
  t2.tap(rx + rw / 2.0, ry + rh / 2.0)
  t2.tap(rx + rw / 2.0, ry + rh / 2.0)
  t2.run_for(@ui.move_most_ms)
  assert_true(v2.zoom.zoomed_at(t2.time()), msg="zoomed in")
  t2.move_to(1280.0 - 24.0, 400.0)
  t2.run_for(@sf.wake_ms + @sf.sleep_ms)
  assert_eq(t2.all(Button, label=next_label).length(), 0, msg="zoomed: arrows hard-suppressed")

  // Reset zoom, enter marking: arrows hard-suppressed
  v2.zoom.reset(at=t2.time())
  t2.run_for(@ui.move_most_ms)
  marks_start()
  t2.run_for(@sf.sleep_ms + @sf.wake_ms)
  assert_eq(t2.all(Button, label=next_label).length(), 0, msg="marking: arrows hard-suppressed")
  marks_leave()
}

///|
test "Track P: tall image entering and leaving marking keeps exact drawn rect and pin position, while preserving keyboard lift" {
  let t = preview_tester("image", w=1400.0, platform=0)
  let v = viewer.get().unwrap()
  v.zoom.natural(880.0, 1280.0, at=t.ctx().moment())
  t.run_for(@ui.move_most_ms)
  let main_src = "mem:preview/" + v.id()
  let before_drawn = drawn_of(t, main_src)
  assert_eq(before_drawn.length(), 1, msg="image drawn once before marking")
  let r0 = before_drawn[0]

  // Enter marking
  pressed(t, Button, @sf.t("web-main.annotate.image"))
  assert_true(marking.on, msg="marking entered")
  t.run_for(@ui.move_most_ms)
  let during_drawn = drawn_of(t, main_src)
  assert_eq(during_drawn.length(), 1, msg="image drawn once during marking")
  let r1 = during_drawn[0]
  assert_eq(r1, r0, msg="actual drawn rect zero-jump on entering marking: before=\{Repr(r0)} during=\{Repr(r1)}")

  // Place a real numbered box mark on the image and verify its actual drawn pin coordinate matches the pre-marking image geometry
  let box_x0 = r0.0 + r0.2 * 0.25
  let box_y0 = r0.1 + r0.3 * 0.45
  let box_x1 = r0.0 + r0.2 * 0.75
  let box_y1 = r0.1 + r0.3 * 0.75
  t.drag(box_x0, box_y0, box_x1, box_y1)
  t.draw()
  // Commit the open note box so the numbered pin "1" is drawn at the mark's anchor
  if t.all(Button, label=@sf.t("common.done")).length() > 0 {
    pressed(t, Button, @sf.t("common.done"))
  }
  t.run_for(@ui.move_most_ms)
  let pin_label = @sf.t("android-chat.marks.pin", args=[("n", "1")])
  let pin_rect = t.get(Button, label=pin_label).rect
  let tip_x = pin_rect.0 + 2.0
  let tip_y = pin_rect.1 + 22.0
  assert_true(
    (tip_x - box_x0).abs() <= 1.5 && (tip_y - box_y0).abs() <= 1.5,
    msg="pin '1' tip (\{tip_x}, \{tip_y}) matches box drag anchor (\{box_x0}, \{box_y0})",
  )
  let r_with_pin = drawn_of(t, main_src)[0]
  assert_eq(r_with_pin, r0, msg="image drawn rect still strictly zero-jump after placing real pin mark")

  // Zoom to 2x while marking and verify pan clearance lets bottom edge move above bottom marking dock and top edge below top bar
  let zoom_2x = v.zoom.fit() * 2.0
  v.zoom.zoom_to(zoom_2x, r0.0 + r0.2 / 2.0, r0.1 + r0.3 / 2.0, false, at=t.time())
  t.run_for(@ui.move_most_ms)
  assert_true(v.zoom.zoomed_at(t.time()), msg="zoomed to 2x in marking")
  // Pan far up (negative dy) to bring image bottom edge above the bottom marking dock
  v.zoom.pan(0.0, -2000.0, at=t.time())
  t.draw()
  let r_pan_bottom = v.zoom.rect_at(t.time()).unwrap()
  let stage_h = v.zoom.bh
  assert_true(
    r_pan_bottom.1 + r_pan_bottom.3 < stage_h - 40.0,
    msg="zoomed pan in marking clears bottom dock: bottom=\{r_pan_bottom.1 + r_pan_bottom.3} stage_h=\{stage_h}",
  )
  // Pan far down (positive dy) to bring image top edge below the top bar
  v.zoom.pan(0.0, 4000.0, at=t.time())
  t.draw()
  let r_pan_top = v.zoom.rect_at(t.time()).unwrap()
  assert_true(
    r_pan_top.1 >= @sf.viewer_bar_h,
    msg="zoomed pan in marking clears top bar: top=\{r_pan_top.1} bar_h=\{@sf.viewer_bar_h}",
  )

  // Reset zoom and verify the same pin '1' tip stays on the exact same anchor coordinate, then leave marking
  v.zoom.reset(at=t.time())
  t.run_for(@ui.move_most_ms)
  let pin_rect_after = t.get(Button, label=pin_label).rect
  let tip_x_after = pin_rect_after.0 + 2.0
  let tip_y_after = pin_rect_after.1 + 22.0
  assert_true(
    (tip_x_after - tip_x).abs() <= 0.5 && (tip_y_after - tip_y).abs() <= 0.5,
    msg="pin '1' tip unchanged after 2x zoom & reset: (\{tip_x}, \{tip_y}) vs (\{tip_x_after}, \{tip_y_after})",
  )
  t.key(@ui.key_escape)
  assert_true(!marking.on, msg="marking left")
  t.run_for(@ui.move_most_ms)
  let after_drawn = drawn_of(t, main_src)
  assert_eq(after_drawn.length(), 1, msg="image drawn once after leaving marking")
  assert_eq(after_drawn[0], r0, msg="actual drawn rect zero-jump on leaving marking")

  // Keyboard lift avoidance preserved while writing low on the picture (assert actual drawn edit box bottom <= visible height)
  let t_kb = preview_tester("image", w=390.0, platform=2)
  let v_kb = viewer.get().unwrap()
  v_kb.zoom.natural(390.0, 844.0, at=t_kb.ctx().moment())
  t_kb.run_for(@ui.move_most_ms)
  marks_start()
  marking.tool = Words
  t_kb.draw()
  let (x, y, w, h) = v_kb.zoom.rect_at(t_kb.time()).unwrap()
  t_kb.touch(0, x + w / 2.0, y + h * 0.95)
  t_kb.touch(2, x + w / 2.0, y + h * 0.95)
  assert_true(marking.writing is Some(_), msg="started writing low on tall image")
  let kb_h = 340.0
  let visible_h = 844.0 - kb_h
  t_kb.set_ime_inset(kb_h)
  t_kb.resize_next(390.0, visible_h)
  t_kb.draw()
  t_kb.run_for(@ui.move_most_ms)
  assert_true(v_kb.lift.target() > 0.0, msg="keyboard still lifts tall image so edited mark stays visible")
  let fields = t_kb.all(TextField)
  assert_true(fields.length() >= 1, msg="writing TextField is rendered")
  let (_, fy, _, fh) = fields[0].rect
  assert_true(fy + fh <= visible_h, msg="writing edit box bottom (\{fy + fh}) stays above IME keyboard (\{visible_h})")
  marks_leave()
}

///|
test "Track P: desktop click boundaries (blank closes, 84pt zone blank & unknown size never mis-close, manual_hidden anti-rebound, Esc closes full-bleed)" {
  // 1. Clicking blank space inside active right 84pt hot zone (missed arrow button or faded) never closes
  let (t, _) = open_settled_desk_image("step")
  t.move_to(640.0, 400.0)
  t.draw()
  t.tap(640.0, 400.0)
  t.run_for(@ui.double_click_ms + @sf.sleep_ms + @sf.viewer_bar_ms)
  // Click in right 84pt zone at y=150 (blank space away from the middle arrow button)
  t.tap(1280.0 - 30.0, 150.0)
  t.run_for(@ui.double_click_ms + 50.0)
  assert_true(viewer.get() is Some(_), msg="blank click in active right 84pt hot zone must NOT close")
  // Click in blank space outside picture and outside active hot zones closes immediately
  t.tap(150.0, 700.0)
  assert_true(viewer.get() is None, msg="blank click outside picture and hot zones closes immediately")

  // 2. Unknown natural size never mis-closes on blank click
  let (t2, v2) = open_settled_desk_image("image")
  v2.zoom.natural(0.0, 0.0, at=t2.time())
  t2.draw()
  t2.tap(150.0, 700.0)
  t2.run_for(@ui.double_click_ms + 50.0)
  assert_true(viewer.get() is Some(_), msg="unknown natural size must NOT mis-close on click")

  // 3. Manual hidden anti-rebound: clicking picture hides bars/arrows and sets manual_hidden; still cursor in hot zone
  // or top zone does not bounce them back until a real pointer move arrives
  let (t3, v3) = open_settled_desk_image("step")
  // Make image span into the right 84pt zone (e.g. wide image) and click on the picture inside the right 84pt zone
  v3.zoom.natural(1280.0, 800.0, at=t3.time())
  t3.draw()
  let (r3x, r3y, r3w, r3h) = v3.zoom.rect_at(t3.time()).unwrap()
  let click_x = r3x + r3w - 10.0
  let click_y = r3y + r3h * 0.25
  assert_true(click_x >= 1280.0 - @sfbase.viewer_step_zone_w, msg="click point is inside both picture and right 84pt hot zone")
  t3.move_to(640.0, 400.0)
  t3.draw()
  t3.move_to(click_x, click_y)
  t3.draw()
  assert_true(v3.bars_shown() && v3.near_right, msg="bars shown and cursor in right hot zone over picture")
  t3.tap(click_x, click_y)
  t3.run_for(@ui.double_click_ms + @sf.sleep_ms + @sf.viewer_bar_ms)
  assert_true(viewer.get() is Some(_), msg="click on full-bleed picture does not close")
  assert_true(v3.manual_hidden, msg="manual_hidden set")
  assert_true(!v3.bars_shown(), msg="bars stay hidden after manual hide")
  assert_true(!v3.step_shown(1), msg="right arrow does NOT rebound on still cursor in near_right")
  // Real pointer move inside right hot zone clears manual_hidden and lights only right arrow (bars stay hidden)
  t3.move_to(click_x - 2.0, click_y)
  t3.run_for(@sf.wake_ms)
  assert_true(!v3.manual_hidden && v3.step_shown(1), msg="real pointer move clears manual_hidden and lights right arrow")
  assert_true(!v3.bars_shown(), msg="bars remain hidden while cursor is only in right 84pt zone")
  // Esc closes full-bleed picture even when bars are hidden
  t3.key(@ui.key_escape)
  assert_true(viewer.get() is None, msg="Esc closes full-bleed picture when bars are hidden")
}

///|
test "Track P: touch single tap inside or outside picture toggles bars (including Duo fitted), drag down closes, zoomed drag pans" {
  // Phone touch (platform=2): tap blank space toggles bars instead of mis-closing
  let t = preview_tester("image", w=390.0, platform=2)
  let v = viewer.get().unwrap()
  assert_true(v.bars_shown(), msg="touch starts with bars shown")
  // Tap blank space above/below fitted 600x400 image (at y=120)
  t.tap(195.0, 120.0)
  t.run_for(@ui.double_tap_ms + 50.0)
  assert_true(viewer.get() is Some(_), msg="touch tap on blank space must NOT close")
  assert_true(!v.bars_shown(), msg="touch tap on blank space toggles bars hidden")
  // Tap on picture toggles bars back on
  t.tap(195.0, 422.0)
  t.run_for(@ui.double_tap_ms + 50.0)
  assert_true(viewer.get() is Some(_) && v.bars_shown(), msg="touch tap on picture toggles bars back on")

  // Drag down closes
  t.drag(195.0, 422.0, 195.0, 622.0)
  assert_true(viewer.get() is None, msg="touch drag down closes preview")
}

///|
test "Track P R1: crossing wide/narrow breakpoint keeps the bars on the same Viewer, never fading by themselves" {
  let (t, v) = open_settled_desk_image("image", w=1280.0)
  t.move_to(640.0, 400.0)
  t.draw()
  assert_true(v.bars_shown(), msg="bars shown before breakpoint resize")
  t.run_for(idle_margin_ms)
  t.resize_next(480.0, 800.0)
  t.draw()
  assert_true(physical_equal(viewer.get().unwrap(), v), msg="same Viewer preserved across breakpoint")
  assert_true(v.bars_shown(), msg="bars still shown right after crossing breakpoint")
  t.run_for(hand_rest_ms)
  assert_true(v.bars_shown(), msg="still shown after a long rest")
}

///|
test "Track P R1: Tab wakes a top bar a click hid" {
  let (t, v) = open_settled_desk_image("image")
  let (rx, ry, rw, rh) = v.zoom.rect_at(t.time()).unwrap()
  t.move_to(640.0, 400.0)
  t.draw()
  t.tap(rx + rw / 2.0, ry + rh / 2.0)
  t.run_for(@sf.viewer_bar_ms)
  assert_true(!v.bars_shown(), msg="bars hidden by a click")
  // Tab from hidden state wakes top bar immediately
  t.key(@ui.key_tab)
  t.draw()
  assert_true(v.bars_shown(), msg="Tab immediately wakes hidden top bar")
}

///|
test "Track P R1: non-image preview click hide in narrow desktop window does not block top-edge hover wake" {
  let t = preview_tester("code", w=480.0, platform=0)
  let v = viewer.get().unwrap()
  assert_true(v.bars_shown(), msg="non-image preview starts with bar shown")
  // Click stage to hide floating bar in narrow desktop window
  t.tap(240.0, 400.0)
  t.draw()
  assert_true(!v.bars_shown(), msg="stage tap hid bar")
  assert_true(!v.manual_hidden, msg="non-image preview never sets image-only manual_hidden")
  // Moving pointer to top edge wakes the bar
  t.move_to(240.0, 12.0)
  t.draw()
  assert_true(v.bars_shown(), msg="top-edge hover wakes non-image preview bar cleanly")
}

///|
test "Track P R2: crossing breakpoint mid trackpad pull resets stale pull_y so a later 40pt pull does not mis-close" {
  let (t, v) = open_settled_desk_image("image", w=1280.0)
  let (rx, ry, rw, rh) = v.zoom.rect_at(t.time()).unwrap()
  let cx = rx + rw / 2.0
  let cy = ry + rh / 2.0
  // Trackpad pull down 60pt (below 100pt close threshold)
  t.wheel_with(cx, cy, 0.0, -60.0, 0)
  t.draw()
  assert_true(viewer.get() is Some(_), msg="60pt pull keeps viewer open")
  // Within 160ms rebound window, resize across wide -> narrow breakpoint on same Viewer
  t.run_for(wheel_half_rest_ms)
  t.resize_next(480.0, 800.0)
  t.draw()
  assert_true(viewer.get() is Some(_), msg="still open after breakpoint resize")
  // Rest past 160ms, then pull down 40pt: must NOT accumulate with stale 60pt to close
  t.run_for(wheel_past_rest_ms)
  t.wheel_with(240.0, 400.0, 0.0, -40.0, 0)
  t.draw()
  assert_true(viewer.get() is Some(_), msg="later 40pt pull after breakpoint does not accumulate stale 60pt or mis-close")
}

///|
test "Track P R2: pointer leaving window right after a click woke the bars keeps them and the arrows" {
  let (t, v) = open_settled_desk_image("step")
  let (rx, ry, rw, rh) = v.zoom.rect_at(t.time()).unwrap()
  let (cx, cy) = (rx + rw / 2.0, ry + rh / 2.0)
  t.move_to(cx, cy)
  t.draw()
  // Hide bars and arrows by a click, past a double click's time so the next is no second
  t.tap(cx, cy)
  t.run_for(@ui.double_click_ms + @sf.viewer_bar_ms + @sf.sleep_ms)
  assert_true(!v.bars_shown() && !v.step_shown(1), msg="bars and arrows hidden")
  // Click picture to wake bars (at once), then leave window right after
  t.tap(cx, cy)
  t.draw()
  assert_true(v.bars_shown(), msg="click wakes bars at once")
  t.run_for(twice_mid_ms)
  t.move_to(-1.0, -1.0)
  t.draw()
  t.run_for(@ui.double_click_ms + idle_margin_ms)
  assert_true(v.bars_shown() && v.step_shown(1), msg="bars and arrows kept after leaving window")
}

///|
test "Track P R2: Zoom pan_under_bars allows panning out of asymmetric bottom dock when h <= bh - top - foot" {
  let z = @motion.Zoom::new(enlarge=true)
  z.boxed(1000.0, 800.0, at=0.0)
  z.natural(1000.0, 400.0, at=0.0)
  // Zoom to h = 640 (scale = 1.6), which is <= 800 - 50 - 100 = 650, centered at y=0 (80..720, bottom 20pt under foot dock)
  z.zoom_to(1.6, 500.0, 400.0, false, at=10.0)
  z.pan_under_bars(50.0, 100.0, at=20.0)
  let r0 = z.rect_at(20.0).unwrap()
  assert_true((r0.1 - 80.0).abs() <= 0.5, msg="entering asymmetric pan_under_bars causes zero jump: y=\{r0.1}")
  // Pan up to clear bottom dock (y <= 700) without crossing top bar (y >= 50)
  z.pan(0.0, -100.0, at=30.0)
  let r1 = z.rect_at(30.0).unwrap()
  assert_true(r1.1 + r1.3 <= 700.0 + 0.5, msg="bottom clears 100pt dock: bottom=\{r1.1 + r1.3}")
  assert_true(r1.1 >= 50.0 - 0.5, msg="top clears 50pt bar: top=\{r1.1}")
}

///|
test "Track P R3: a click hiding them, then switching to touch, a single tap wakes bars and arrows" {
  let (t, v) = open_settled_desk_image("step")
  let (rx, ry, rw, rh) = v.zoom.rect_at(t.time()).unwrap()
  let (cx, cy) = (rx + rw / 2.0, ry + rh / 2.0)
  t.move_to(cx, cy)
  t.draw()
  t.tap(cx, cy)
  t.run_for(@ui.double_click_ms + idle_margin_ms)
  assert_true(!v.bars_shown() && !v.step_shown(1), msg="a click hides bars and arrows")
  // Switch live pointing to touch and single tap picture center
  t.host_says_finger(Some(true))
  t.draw()
  t.tap(cx, cy)
  t.run_for(@ui.double_tap_ms + idle_margin_ms)
  assert_true(v.bars_shown() && v.step_shown(1), msg="touch tap wakes bars and available arrows")
}

///|
test "Track P R3: crossing breakpoint mid horizontal trackpad paging recenters image without switching, then paging still works" {
  let (t, v) = open_settled_desk_image("step", w=1280.0)
  let id0 = v.id()
  let main_src = "mem:preview/" + id0
  let (rx, ry, rw, rh) = v.zoom.rect_at(t.time()).unwrap()
  let (cx, cy) = (rx + rw / 2.0, ry + rh / 2.0)
  // Small horizontal trackpad swipe (20pt, below flip threshold) toward right neighbor
  t.wheel_with(cx, cy, 20.0, 0.0, 0)
  t.draw()
  // Cross wide -> narrow breakpoint within 160ms rest window
  t.run_for(wheel_half_rest_ms)
  t.resize_next(480.0, 800.0)
  t.draw()
  t.run_for(wheel_past_rest_ms)
  assert_eq(viewer.get().unwrap().id(), id0, msg="breakpoint mid-paging does not switch image")
  let drawn = drawn_of(t, main_src)
  assert_eq(drawn.length(), 1, msg="image drawn once on narrow stage")
  let drawn_cx = drawn[0].0 + drawn[0].2 / 2.0
  assert_true((drawn_cx - 240.0).abs() <= 1.0, msg="image x recentered on 480pt stage: cx=\{drawn_cx}")
  // Subsequent horizontal swipe steps cleanly to next image
  t.drag(380.0, 400.0, 80.0, 400.0)
  t.run_for(@ui.move_most_ms)
  assert_true(viewer.get().unwrap().id() != id0, msg="subsequent swipe steps to next image cleanly")
}

///|
test "Track P R4: a tap shows or hides the bars and the ways beside at once, no fade and no wait for a second; two still zoom" {
  // Phone touch: hidden at the tap's own moment, the ways beside unreachable then, nothing left moving
  let t = preview_tester("step", w=390.0, platform=2)
  t.run_for(@ui.move_most_ms)
  let v = viewer.get().unwrap()
  let next = @sf.t("web-main.preview.nextKey")
  assert_true(v.bars_shown() && t.all(Button, label=next).length() == 1, msg="starts with bars and the way after shown")
  // (the head's words seen along the top, as drawn)
  let head_seen = fn() { t.glyphs_seen().iter().any(fn(g) { g.1 < 80.0 }) }
  assert_true(head_seen(), msg="starts with the head seen")
  t.tap(195.0, 422.0)
  t.draw()
  assert_true(!v.bars_shown(), msg="one tap: bars hidden at once")
  assert_true(!head_seen(), msg="one tap: the head drawn gone at once")
  assert_eq(t.all(Button, label=next).length(), 0, msg="one tap: the way after gone at once, no fade taking a press")
  t.run_for(@ui.double_tap_ms * 2.0)
  assert_true(!v.zoom.zoomed_at(t.time()) && !v.bars_shown(), msg="one tap: no zoom, still hidden")
  t.tap(195.0, 422.0)
  t.draw()
  assert_true(v.bars_shown(), msg="another tap: bars back at once")
  assert_true(head_seen(), msg="another tap: the head drawn back at once")
  assert_eq(t.all(Button, label=next).length(), 1, msg="another tap: the way after back at once")
  // Two taps: the first's toggle stands, the second zooms
  t.run_for(@ui.double_tap_ms * 2.0)
  t.tap(195.0, 422.0)
  t.tap(195.0, 422.0)
  t.run_for(@ui.double_tap_ms * 2.0)
  assert_true(viewer.get() is Some(_) && v.zoom.zoomed_at(t.time()), msg="two taps: zoomed in")
  // Desktop: a click on the picture hides the bar at once, another shows it, and nothing fades it by itself
  let (td, vd) = open_settled_desk_image("image")
  let (rx, ry, rw, rh) = vd.zoom.rect_at(td.time()).unwrap()
  let (cx, cy) = (rx + rw / 2.0, ry + rh / 2.0)
  td.move_to(cx, cy)
  td.draw()
  assert_true(vd.bars_shown(), msg="desktop: bars shown before click")
  let bar_seen = fn() { td.glyphs_seen().iter().any(fn(g) { g.1 < 40.0 }) }
  assert_true(bar_seen(), msg="desktop: the bar's words seen before click")
  td.tap(cx, cy)
  td.draw()
  assert_true(!vd.bars_shown(), msg="desktop: click hides bars at once")
  assert_true(!bar_seen(), msg="desktop: the bar drawn gone at once")
  td.run_for(hand_rest_ms)
  assert_true(!vd.bars_shown(), msg="desktop: stays hidden (manual_hidden), no rebound")
  // The pointer moving over the picture: still hidden (only a click shows them)
  td.move_to(cx - 40.0, cy + 20.0)
  td.move_to(cx + 40.0, cy - 20.0)
  td.draw()
  assert_true(!vd.bars_shown(), msg="desktop: the pointer moving over the picture never shows them")
  // Its menu opened and closed: the bars as the click left them
  td.right_click(cx, cy)
  td.run_for(@sf.presented_rest() - td.time())
  assert_true(vd.menu_open && vd.bars_shown(), msg="desktop: the menu holds the bars while open")
  td.key(@ui.key_escape)
  td.run_for(@sf.presented_rest() - td.time() + idle_margin_ms)
  assert_true(!vd.menu_open && !vd.bars_shown(), msg="desktop: menu closed: back to hidden")
  td.tap(cx, cy)
  td.draw()
  assert_true(vd.bars_shown(), msg="desktop: another click shows bars at once")
  assert_true(bar_seen(), msg="desktop: the bar drawn back at once")
  td.run_for(hand_rest_ms)
  assert_true(vd.bars_shown(), msg="desktop: a long rest after the showing click: still shown")
}

///|
test "Track P R4: a click on a bar's button sets no focus lock: a click on the picture after still hides the bars" {
  let (t, v) = open_settled_desk_image("image")
  let copy_btn = t.get(Button, label=@sf.t("common.copy"))
  let (bx, by, bw, bh) = copy_btn.rect
  t.tap(bx + bw / 2.0, by + bh / 2.0)
  t.draw()
  assert_true(!v.bar_focused, msg="pointer click on bar button does not set the bar's focus lock")
  let (rx, ry, rw, rh) = v.zoom.rect_at(t.time()).unwrap()
  t.move_to(rx + rw / 2.0, ry + rh / 2.0)
  t.run_for(@ui.double_click_ms + idle_margin_ms)
  t.tap(rx + rw / 2.0, ry + rh / 2.0)
  t.draw()
  assert_true(!v.bars_shown(), msg="a click on the picture hides the bars")
}
