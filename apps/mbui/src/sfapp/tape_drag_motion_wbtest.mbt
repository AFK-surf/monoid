// 中屏磁带拖拽明暗实时联动与甩手初速度接棒（sfdesk/tape_view.mbt）。

///|
test "中屏磁带拖动切栏过程，面板明暗随拖动距离实时插值且松手不跳变" {
  let t = tape_chat(2, 720.0, 840.0, width="medium", height="medium")
  page_over(t, 720.0)
  assert_eq(@sfdesk.wide.tape_at.get(), @sfdesk.TapePane::Page)
  let b_page_0 = @sfdesk.tape_behind_now(Page, t.time())
  let b_side_0 = @sfdesk.tape_behind_now(Side, t.time())
  assert_true(b_page_0 < 0.01 && b_side_0 > 0.99, msg="rest: page=\{b_page_0}, side=\{b_side_0}")
  // (drag right on Page to pull Side out)
  let x0 = 160.0
  let y0 = 360.0
  t.touch(0, x0, y0)
  for dx in [40.0, 90.0, 140.0] {
    t.advance(@ui.input_step_ms)
    t.touch(1, x0 + dx, y0)
  }
  let b_page_mid = @sfdesk.tape_behind_now(Page, t.time())
  let b_side_mid = @sfdesk.tape_behind_now(Side, t.time())
  assert_true(b_page_mid > 0.15 && b_page_mid < 0.95, msg="mid drag page behind: \{b_page_mid}")
  assert_true(b_side_mid > 0.05 && b_side_mid < 0.85, msg="mid drag side behind: \{b_side_mid}")
  assert_true((b_page_mid + b_side_mid - 1.0).abs() < 0.02, msg="complementary behind: page=\{b_page_mid}, side=\{b_side_mid}")
  // (release past threshold: no jump at release moment)
  t.advance(@ui.input_step_ms)
  t.touch(2, x0 + 140.0, y0)
  let b_page_rel = @sfdesk.tape_behind_now(Page, t.time())
  let b_side_rel = @sfdesk.tape_behind_now(Side, t.time())
  assert_true((b_page_rel - b_page_mid).abs() < 0.02, msg="page behind jump at release: mid=\{b_page_mid}, rel=\{b_page_rel}")
  assert_true((b_side_rel - b_side_mid).abs() < 0.02, msg="side behind jump at release: mid=\{b_side_mid}, rel=\{b_side_rel}")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfdesk.wide.tape_at.get(), @sfdesk.TapePane::Side)
  assert_true(@sfdesk.tape_behind_now(Side, t.time()) < 0.01)
  assert_true(@sfdesk.tape_behind_now(Page, t.time()) > 0.99)
}

///|
/// Pull Side from Page by `dx` over `steps` moves, pause `pause_ms` before lifting; return displacement over the
/// first 2 frames after release, and final x at rest.
fn tape_release_step(dx : Double, steps : Int, pause_ms : Double) -> (Double, Double, Double) {
  let t = tape_chat(2, 720.0, 840.0, width="medium", height="medium")
  page_over(t, 720.0)
  let x0 = 160.0
  let y0 = 360.0
  t.touch(0, x0, y0)
  for i in 1..=steps {
    t.advance(@ui.input_step_ms)
    t.touch(1, x0 + dx * i.to_double() / steps.to_double(), y0)
  }
  if pause_ms > 0.0 {
    t.advance(pause_ms)
  }
  let x_rel = tape_now().0
  t.touch(2, x0 + dx, y0)
  let d2 = if @ui.test_at_a_rate() {
    0.0
  } else {
    t.frame()
    t.frame()
    tape_now().0 - x_rel
  }
  t.run_for(@ui.move_most_ms)
  (d2, tape_now().0, x_rel)
}

///|
test "中屏磁带高速甩手松手后前 2 帧位移显著大于静止松手，且收尾不越过稳态" {
  // (both pulled 110pt right, past threshold so both settle on Side; fast flick has high release velocity,
  // slow pause has ~0 velocity)
  let (fast_d2, fast_end, _) = tape_release_step(110.0, 3, 0.0)
  let (slow_d2, slow_end, _) = tape_release_step(110.0, 12, @ui.input_step_ms * 6.0)
  assert_true((fast_end - slow_end).abs() < 0.5, msg="same settled target: fast=\{fast_end}, slow=\{slow_end}")
  if !@ui.test_at_a_rate() {
    assert_true(fast_d2 > slow_d2 + 8.0, msg="fast flick should cover more in first 2 frames: fast=\{fast_d2}, slow=\{slow_d2}")
    assert_true(fast_end <= 0.5, msg="settled at Side x=0 without overshoot: \{fast_end}")
  }
}
