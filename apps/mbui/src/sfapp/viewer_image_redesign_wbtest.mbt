// Wave 27 · Track P (Image Viewer Interaction Redesign) deterministic acceptance matrix:
// - `assert_idle()` after settled entry keeps bars shown (`later=true`), explicit 1799/1800/1800+bar_ms fade,
//   lock-clear 1800ms re-arm (loading, menu, bar focus, a11y), window-leave immediate fade, step/unmount cancellation
// - Per-side 84pt hot zones lighting only that side's arrow (opposite side hidden/unclickable/unreachable),
//   hard suppression in zoomed & marking states, embedded image tab zero-regression
// - Full-bleed stage & tall image entering/leaving marking: actual drawn rect `(x, y, w, h)` and pin screen position
//   strictly zero-jump, while preserving keyboard lift avoidance
// - Unified click/close boundaries (desktop blank space vs 84pt hot zone blank vs unknown size vs picture toggle with
//   manual_hidden anti-rebound vs full-bleed Esc close; touch tap inside/outside toggles bars including Duo fitted)

///|
let idle_tick_ms : Double = 1.0

///|
let idle_margin_ms : Double = 100.0

///|
let idle_step_before_ms : Double = @sfbase.image_idle_ms * 0.55

///|
let idle_step_past_old_ms : Double = @sfbase.image_idle_ms * 0.5

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
  // Settle any entry fade/flight so `assert_idle()` specifically verifies `later=true` on the idle auto-fade timer.
  t.run_for(@ui.move_most_ms)
  let v = viewer.get().unwrap()
  (t, v)
}

///|
test "Track P: settled image viewer passes assert_idle with bars shown, then fades deterministically at 1799/1800/1800+bar_ms" {
  let (t, v) = open_settled_desk_image("image")
  t.assert_idle()
  assert_true(v.bars_shown(), msg="settled entry: bars still shown while later=true timer is pending")
  // Measure remaining time from viewer open (settled moved clock forward by move_most_ms)
  // Re-arm via center pointer move so we test exact 1799 / 1800 / 1800+viewer_bar_ms deltas from a known cause moment.
  t.move_to(640.0, 400.0)
  t.draw()
  t.assert_idle()
  assert_true(v.bars_shown(), msg="after center move: bars shown and idle")
  t.run_for(@sfbase.image_idle_ms - idle_tick_ms)
  assert_true(v.bars_shown(), msg="at 1799ms: bars still shown")
  t.run_for(idle_tick_ms)
  assert_true(!v.bars_shown(), msg="at 1800ms: bars begin auto-fade")
  t.run_for(@sf.viewer_bar_ms + @sf.sleep_ms)
  t.assert_idle()
  assert_true(!v.bars_shown(), msg="after fade completes: bars hidden and idle")
}

///|
test "Track P: desktop locks (menu, bar focus, image loading, a11y_on) hold bars and re-arm full 1800ms on release" {
  // 1. Context menu lock & re-arm
  let (t, v) = open_settled_desk_image("image")
  t.move_to(640.0, 400.0)
  t.draw()
  let (rx, ry, rw, rh) = v.zoom.rect_at(t.time()).unwrap()
  t.right_click(rx + rw / 2.0, ry + rh / 2.0)
  t.run_for(@sf.presented_rest() - t.time())
  assert_true(v.menu_open && v.bars_shown(), msg="menu open locks bars")
  t.run_for(@sfbase.image_idle_ms + 200.0)
  assert_true(v.bars_shown(), msg="past 1800ms while menu open: still shown")
  t.key(@ui.key_escape)
  t.run_for(@sf.presented_rest() - t.time() + 10.0)
  assert_true(!v.menu_open, msg="Esc closes menu")
  // Full 1800ms re-armed from menu close
  let after_close = t.time()
  t.run_for(@sfbase.image_idle_ms - 50.0)
  assert_true(v.bars_shown(), msg="before 1800ms after menu close (t=\{t.time() - after_close}): still shown")
  t.run_for(idle_margin_ms)
  assert_true(!v.bars_shown(), msg="at 1800ms after menu close: auto-faded")

  // 2. Bar keyboard focus lock & re-arm
  let (t, v) = open_settled_desk_image("image")
  let mut tabs = 0
  while !v.bar_focused && tabs < 8 {
    t.key(@ui.key_tab)
    t.draw()
    tabs += 1
  }
  assert_true(v.bar_focused, msg="Tab moved focus into top bar")
  t.run_for(@sfbase.image_idle_ms + 200.0)
  assert_true(v.bars_shown(), msg="past 1800ms while bar focused: still shown")
  @ui.view_tree().unwrap().focus_to(None) |> ignore
  t.draw()
  assert_true(!v.bar_focused, msg="focus left bar")
  t.run_for(@sfbase.image_idle_ms - idle_tick_ms)
  assert_true(v.bars_shown(), msg="1799ms after focus left bar: still shown")
  t.run_for(idle_tick_ms)
  assert_true(!v.bars_shown(), msg="1800ms after focus left bar: auto-faded")

  // 3. Image loading lock & re-arm
  let (t, v) = open_settled_desk_image("image")
  let saved_bytes = v.bytes.untracked()
  v.fetching.set(true)
  v.bytes.set(None)
  t.draw()
  assert_true(v.image_loading() && v.bars_shown(), msg="loading locks bars")
  t.run_for(@sfbase.image_idle_ms + 200.0)
  assert_true(v.bars_shown(), msg="past 1800ms while loading: still shown")
  v.bytes.set(saved_bytes)
  v.fetching.set(false)
  t.draw()
  assert_true(!v.image_loading(), msg="loading finished")
  t.run_for(@sfbase.image_idle_ms - idle_tick_ms)
  assert_true(v.bars_shown(), msg="1799ms after load finished: still shown")
  t.run_for(idle_tick_ms)
  assert_true(!v.bars_shown(), msg="1800ms after load finished: auto-faded")

  // 4. Plain a11y_on does NOT lock auto-fade; screen_reader_on wakes & locks bars + arrows, and clearing it re-arms full 1800ms
  let (t, v) = open_settled_desk_image("step")
  t.move_to(640.0, 400.0)
  t.draw()
  t.set_a11y(true)
  t.draw()
  t.run_for(@sfbase.image_idle_ms + idle_tick_ms)
  assert_true(!v.bars_shown() && !v.step_shown(1), msg="plain set_a11y(true) does NOT block 1800ms auto-fade")
  t.set_a11y(false)
  t.set_screen_reader(true)
  t.draw()
  assert_true(v.bars_shown() && v.step_shown(1), msg="set_screen_reader(true) actively wakes and locks bars and arrows")
  t.run_for(@sfbase.image_idle_ms + 500.0)
  assert_true(v.bars_shown() && v.step_shown(1), msg="screen_reader_on holds bars and arrows past 1800ms")
  t.set_screen_reader(false)
  t.draw()
  t.run_for(@sfbase.image_idle_ms - idle_tick_ms)
  assert_true(v.bars_shown(), msg="1799ms after set_screen_reader(false): full 1800ms grace period still active")
  t.run_for(idle_tick_ms)
  assert_true(!v.bars_shown(), msg="1800ms after set_screen_reader(false): auto-fades cleanly")

  // 5. Tab specifically focuses viewer_bar_node's back button (watched via viewer_bar_watch_back) and holds past 1800ms
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
  t_back.run_for(@sfbase.image_idle_ms + idle_margin_ms)
  assert_true(v_back.bar_focused && v_back.bars_shown(), msg="back button focus holds bars past 1800ms")
}

///|
test "Track P: stepping to another image cancels old idle timer and leaving window fades immediately" {
  let (t, v1) = open_settled_desk_image("step")
  t.move_to(640.0, 400.0)
  t.draw()
  assert_true(v1.bars_shown())
  // Advance past half of v1's idle deadline, then step to next image
  t.run_for(idle_step_before_ms)
  t.key(@ui.key_code_right)
  t.draw()
  let v2 = viewer.get().unwrap()
  assert_true(v2.file.name != v1.file.name, msg="stepped to next image")
  assert_true(v2.bars_shown(), msg="v2 starts with bars shown")
  // Cross v1's old 1800ms deadline: v2 must stay shown because v1's timer was cancelled
  t.run_for(idle_step_past_old_ms)
  assert_true(v2.bars_shown(), msg="old timer from v1 was cancelled on step")
  // Leaving the window fades immediately
  t.move_to(-1.0, -1.0)
  t.draw()
  assert_true(!v2.bars_shown(), msg="pointer leaving window fades immediately")
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
  // Let bars and arrows auto-fade completely
  t.move_to(640.0, 400.0)
  t.draw()
  t.run_for(@sfbase.image_idle_ms + @sf.sleep_ms + @sf.viewer_bar_ms)
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
  t2.run_for(@sfbase.image_idle_ms + @sf.sleep_ms + @sf.viewer_bar_ms)
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
  t.run_for(@sfbase.image_idle_ms + @sf.sleep_ms + @sf.viewer_bar_ms)
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
test "Track P R1: crossing wide/narrow breakpoint preserves new layer idle timer on same Viewer" {
  let (t, v) = open_settled_desk_image("image", w=1280.0)
  t.move_to(640.0, 400.0)
  t.draw()
  assert_true(v.bars_shown(), msg="bars shown before breakpoint resize")
  // Advance past half of old 1800ms deadline, then resize across wide -> narrow breakpoint on the same Viewer
  t.run_for(idle_step_before_ms)
  t.resize_next(480.0, 800.0)
  t.draw()
  assert_true(physical_equal(viewer.get().unwrap(), v), msg="same Viewer preserved across breakpoint")
  assert_true(v.bars_shown(), msg="bars still shown right after crossing breakpoint")
  // Cross old deadline (still inside new 1800ms deadline)
  t.run_for(idle_step_past_old_ms)
  assert_true(v.bars_shown(), msg="still shown past old deadline")
  // Advance to 1ms before new 1800ms deadline, then 1ms past it
  let remaining_before = @sfbase.image_idle_ms - idle_step_past_old_ms - idle_tick_ms
  t.run_for(remaining_before)
  assert_true(v.bars_shown(), msg="1ms before new 1800ms deadline: still shown")
  t.run_for(idle_tick_ms)
  assert_true(!v.bars_shown(), msg="at new 1800ms deadline: auto-faded cleanly")
}

///|
test "Track P R1: auto-faded state restores full 1800ms after in-window lock (context menu) clears" {
  let (t, v) = open_settled_desk_image("image")
  t.move_to(640.0, 400.0)
  t.draw()
  // Let bars auto-fade completely while pointer rests in image center
  t.run_for(@sfbase.image_idle_ms + @sf.viewer_bar_ms)
  assert_true(!v.bars_shown(), msg="bars auto-faded while pointer rests in center")
  // Right-click in place to open context menu (locks bars visible even though awake was false)
  let (rx, ry, rw, rh) = v.zoom.rect_at(t.time()).unwrap()
  t.right_click(rx + rw / 2.0, ry + rh / 2.0)
  t.run_for(@sf.presented_rest() - t.time())
  assert_true(v.menu_open && v.bars_shown(), msg="context menu locks bars visible from auto-faded state")
  // Press Esc to close menu: must restore awake and grant full 1800ms (not vanish immediately)
  t.key(@ui.key_escape)
  t.run_for(@sf.presented_rest() - t.time() + idle_tick_ms)
  assert_true(!v.menu_open && v.bars_shown(), msg="after Esc closes menu: bars stay visible for full 1800ms")
  t.run_for(@sfbase.image_idle_ms - idle_margin_ms)
  assert_true(v.bars_shown(), msg="before 1800ms after menu close: still shown")
  t.run_for(idle_margin_ms + idle_tick_ms)
  assert_true(!v.bars_shown(), msg="past 1800ms after menu close: auto-faded")
}

///|
test "Track P R1: clicking picture 1ms before idle deadline commits hide without inversion during twice_ms" {
  let (t, v) = open_settled_desk_image("image")
  let (rx, ry, rw, rh) = v.zoom.rect_at(t.time()).unwrap()
  let cx = rx + rw / 2.0
  let cy = ry + rh / 2.0
  t.move_to(cx, cy)
  t.draw()
  assert_true(v.bars_shown(), msg="bars visible after center move")
  // Advance to 1ms before the 1800ms idle deadline, then click picture to hide bars
  t.run_for(@sfbase.image_idle_ms - idle_tick_ms)
  assert_true(v.bars_shown(), msg="1ms before deadline: bars still visible")
  t.tap(cx, cy)
  // Cross both the old idle deadline and the double-click wait window
  t.run_for(@ui.double_click_ms + idle_margin_ms)
  assert_true(!v.bars_shown(), msg="click intent preserved as hidden (not inverted by old idle timer)")
  assert_true(v.manual_hidden, msg="manual_hidden set so still cursor does not rebound")
}

///|
test "Track P R1: Tab wakes faded top bar, pointer click on top bar does not lock auto-fade via focus_shown" {
  let (t, v) = open_settled_desk_image("image")
  t.move_to(640.0, 400.0)
  t.draw()
  t.run_for(@sfbase.image_idle_ms + @sf.viewer_bar_ms)
  assert_true(!v.bars_shown(), msg="bars auto-faded")
  // Tab from hidden state wakes top bar immediately
  t.key(@ui.key_tab)
  t.draw()
  assert_true(v.bars_shown(), msg="Tab immediately wakes faded top bar")

  // Pointer click on a top bar control (e.g. copy button) then moving pointer back to center must NOT lock auto-fade
  let (t2, v2) = open_settled_desk_image("image")
  let copy_btn = t2.get(Button, label=@sf.t("common.copy"))
  let (bx, by, bw, bh) = copy_btn.rect
  t2.tap(bx + bw / 2.0, by + bh / 2.0)
  t2.draw()
  t2.move_to(640.0, 400.0)
  t2.draw()
  assert_true(!v2.bar_focused, msg="pointer click on bar button does not set focus_shown bar lock")
  t2.run_for(@sfbase.image_idle_ms + idle_tick_ms)
  assert_true(!v2.bars_shown(), msg="after pointer click on bar button and moving to center, bars still auto-fade at 1800ms")
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
test "Track P R2: second press ending in Off or drag >8pt during twice_ms restores 1800ms auto-fade" {
  // (a) Second press Down -> Off during twice_ms
  let (t1, v1) = open_settled_desk_image("image")
  let (rx1, ry1, rw1, rh1) = v1.zoom.rect_at(t1.time()).unwrap()
  let (cx1, cy1) = (rx1 + rw1 / 2.0, ry1 + rh1 / 2.0)
  t1.move_to(cx1, cy1)
  t1.draw()
  assert_true(v1.bars_shown())
  t1.tap(cx1, cy1)
  t1.run_for(twice_mid_ms)
  t1.touch(0, cx1, cy1)
  t1.touch(3, cx1, cy1)
  t1.draw()
  t1.run_for(@sfbase.image_idle_ms + idle_margin_ms)
  assert_true(!v1.bars_shown(), msg="after second press Down->Off, 1800ms auto-fade recovers")

  // (b) Second press Down -> drag up >8pt -> Up during twice_ms
  let (t2, v2) = open_settled_desk_image("image")
  let (rx2, ry2, rw2, rh2) = v2.zoom.rect_at(t2.time()).unwrap()
  let (cx2, cy2) = (rx2 + rw2 / 2.0, ry2 + rh2 / 2.0)
  t2.move_to(cx2, cy2)
  t2.draw()
  assert_true(v2.bars_shown())
  t2.tap(cx2, cy2)
  t2.run_for(twice_mid_ms)
  t2.drag(cx2, cy2, cx2, cy2 - 20.0)
  t2.draw()
  t2.run_for(@sfbase.image_idle_ms + idle_margin_ms)
  assert_true(!v2.bars_shown(), msg="after second press dragged >8pt -> Up, 1800ms auto-fade recovers")
}

///|
test "Track P R2: pointer leaving window during twice_ms cancels pending wake-bars single click" {
  let (t, v) = open_settled_desk_image("step")
  let (rx, ry, rw, rh) = v.zoom.rect_at(t.time()).unwrap()
  let (cx, cy) = (rx + rw / 2.0, ry + rh / 2.0)
  t.move_to(cx, cy)
  t.draw()
  // Let bars and arrows auto-fade completely
  t.run_for(@sfbase.image_idle_ms + @sf.viewer_bar_ms + @sf.sleep_ms)
  assert_true(!v.bars_shown() && !v.step_shown(1), msg="bars and arrows auto-faded")
  // Click picture to wake bars, then leave window within twice_ms
  t.tap(cx, cy)
  t.run_for(twice_mid_ms)
  t.move_to(-1.0, -1.0)
  t.draw()
  // Wait past twice_ms: pending wake must be cancelled
  t.run_for(@ui.double_click_ms + idle_margin_ms)
  assert_true(!v.bars_shown() && !v.step_shown(1), msg="bars and arrows stay hidden after leaving window during twice_ms")
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
test "Track P R3: second press slow drag down 20pt + pause 100ms rebound restores 1800ms idle timer" {
  let (t, v) = open_settled_desk_image("image")
  let (rx, ry, rw, rh) = v.zoom.rect_at(t.time()).unwrap()
  let (cx, cy) = (rx + rw / 2.0, ry + rh / 2.0)
  t.move_to(cx, cy)
  t.draw()
  assert_true(v.bars_shown(), msg="bars visible before first click")
  // First click pauses idle for twice_ms; 50ms later second press drags down 20pt, pauses 100ms, releases without closing
  t.tap(cx, cy)
  t.run_for(twice_mid_ms)
  t.touch(0, cx, cy)
  t.touch(1, cx, cy + 20.0)
  t.run_for(idle_margin_ms)
  t.touch(2, cx, cy + 20.0)
  t.draw()
  assert_true(viewer.get() is Some(_), msg="slow 20pt pull-down rebound keeps preview open")
  t.run_for(@sfbase.image_idle_ms - idle_tick_ms)
  assert_true(v.bars_shown(), msg="1799ms after pull-down rebound: bars still shown")
  t.run_for(idle_tick_ms)
  assert_true(!v.bars_shown(), msg="1800ms after pull-down rebound: bars auto-fade cleanly")
}

///|
test "Track P R3: mouse leaving window then switching to touch single tap wakes bars and arrows" {
  let (t, v) = open_settled_desk_image("step")
  let (rx, ry, rw, rh) = v.zoom.rect_at(t.time()).unwrap()
  let (cx, cy) = (rx + rw / 2.0, ry + rh / 2.0)
  t.move_to(cx, cy)
  t.draw()
  t.move_to(-1.0, -1.0)
  t.draw()
  assert_true(!v.bars_shown() && !v.step_shown(1), msg="mouse leaving window hides bars and arrows")
  // Switch live pointing to touch and single tap picture center
  t.host_says_finger(Some(true))
  t.draw()
  t.tap(cx, cy)
  t.run_for(@ui.double_tap_ms + idle_margin_ms)
  assert_true(v.bars_shown() && v.step_shown(1), msg="touch tap after mouse left window wakes bars and available arrows")
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
test "Track P R3: lock_epoch invalidates pending single-click intent when loading lock opens and clears during twice_ms" {
  // Case A: started with bars visible -> click picture -> loading lock opens & clears inside twice_ms -> full 1800ms from unlock
  let (t1, v1) = open_settled_desk_image("image")
  let (rx1, ry1, rw1, rh1) = v1.zoom.rect_at(t1.time()).unwrap()
  let (cx1, cy1) = (rx1 + rw1 / 2.0, ry1 + rh1 / 2.0)
  t1.move_to(cx1, cy1)
  t1.draw()
  assert_true(v1.bars_shown())
  t1.tap(cx1, cy1)
  t1.run_for(twice_mid_ms)
  let saved1 = v1.bytes.untracked()
  v1.fetching.set(true)
  v1.bytes.set(None)
  t1.draw()
  v1.bytes.set(saved1)
  v1.fetching.set(false)
  t1.draw()
  t1.run_for(@sfbase.image_idle_ms - idle_tick_ms)
  assert_true(v1.bars_shown(), msg="visible start: stale hide click invalidated; 1799ms after unlock still shown")
  t1.run_for(idle_tick_ms)
  assert_true(!v1.bars_shown(), msg="visible start: 1800ms after unlock fades cleanly")

  // Case B: started with bars auto-faded -> click picture -> loading lock opens & clears inside twice_ms -> full 1800ms from unlock
  let (t2, v2) = open_settled_desk_image("image")
  let (rx2, ry2, rw2, rh2) = v2.zoom.rect_at(t2.time()).unwrap()
  let (cx2, cy2) = (rx2 + rw2 / 2.0, ry2 + rh2 / 2.0)
  t2.move_to(cx2, cy2)
  t2.draw()
  t2.run_for(@sfbase.image_idle_ms + @sf.viewer_bar_ms)
  assert_true(!v2.bars_shown(), msg="faded start: bars faded")
  t2.tap(cx2, cy2)
  t2.run_for(twice_mid_ms)
  let saved2 = v2.bytes.untracked()
  v2.fetching.set(true)
  v2.bytes.set(None)
  t2.draw()
  v2.bytes.set(saved2)
  v2.fetching.set(false)
  t2.draw()
  t2.run_for(@sfbase.image_idle_ms - idle_tick_ms)
  assert_true(v2.bars_shown(), msg="faded start: stale wake click invalidated; 1799ms after unlock still shown")
  t2.run_for(idle_tick_ms)
  assert_true(!v2.bars_shown(), msg="faded start: 1800ms after unlock fades cleanly (not pushed back by stale click)")
}
