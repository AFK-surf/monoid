// Deterministic unit tests for libs/ui/src/host/frame_pace.h
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "frame_pace.h"

static int failures = 0;

#define CHECK(cond)                                                              \
  do {                                                                           \
    if (!(cond)) {                                                               \
      fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);            \
      failures++;                                                                \
    }                                                                            \
  } while (0)

static int approx(double a, double b, double eps) { return fabs(a - b) <= eps; }

static void test_every_edges(void) {
  double nan_v = NAN;
  double inf_v = INFINITY;
  CHECK(mb_frame_pace_every(nan_v, 20.0) == 1);
  CHECK(mb_frame_pace_every(60.0, nan_v) == 1);
  CHECK(mb_frame_pace_every(inf_v, 20.0) == 1);
  CHECK(mb_frame_pace_every(60.0, inf_v) == 1);
  CHECK(mb_frame_pace_every(60.0, -inf_v) == 1);
  CHECK(mb_frame_pace_every(0.0, 20.0) == 1);
  CHECK(mb_frame_pace_every(-60.0, 20.0) == 1);
  CHECK(mb_frame_pace_every(1001.0, 20.0) == 1);
  CHECK(mb_frame_pace_every(60.0, 0.0) == 1);
  CHECK(mb_frame_pace_every(60.0, -10.0) == 1);
  // Very small req_hz (including DBL_MIN) clamps to 1000 without Inf overflow
  CHECK(mb_frame_pace_every(120.0, DBL_MIN) == 1000);
  CHECK(mb_frame_pace_every(120.0, 1e-9) == 1000);
  CHECK(mb_frame_pace_every(120.0, 0.01) == 1000);
  // Ratio < 1.5 -> 1; ratio == 1.5 -> 2
  CHECK(mb_frame_pace_every(60.0, 60.0) == 1);
  CHECK(mb_frame_pace_every(60.0, 45.0) == 1);
  CHECK(mb_frame_pace_every(60.0, 40.0) == 2);
  // Standard refresh rates
  CHECK(mb_frame_pace_every(60.0, 20.0) == 3);
  CHECK(mb_frame_pace_every(60.0, 30.0) == 2);
  CHECK(mb_frame_pace_every(120.0, 20.0) == 6);
  CHECK(mb_frame_pace_every(120.0, 30.0) == 4);
  CHECK(mb_frame_pace_every(144.0, 20.0) == 7);
  CHECK(mb_frame_pace_every(165.0, 20.0) == 8);
  // 240Hz with beats=2 -> top_hz = 120Hz -> 20Hz gives every=6 (not 12)
  CHECK(mb_frame_pace_every(240.0 / 2.0, 20.0) == 6);
  CHECK(mb_frame_pace_every(240.0, 20.0) == 12);
}

static void test_tick_wake_ms(void) {
  CHECK(mb_frame_pace_tick_wake_ms(NAN, 3) == 0.0);
  CHECK(mb_frame_pace_tick_wake_ms(INFINITY, 3) == 0.0);
  CHECK(mb_frame_pace_tick_wake_ms(0.0, 3) == 0.0);
  CHECK(mb_frame_pace_tick_wake_ms(-16.0, 3) == 0.0);
  CHECK(mb_frame_pace_tick_wake_ms(16.6667, 1) == 0.0);
  CHECK(mb_frame_pace_tick_wake_ms(16.6667, 0) == 0.0);
  CHECK(approx(mb_frame_pace_tick_wake_ms(1000.0 / 60.0, 3), 2.5 * (1000.0 / 60.0), 1e-9));
  CHECK(approx(mb_frame_pace_tick_wake_ms(1000.0 / 120.0, 6), 5.5 * (1000.0 / 120.0), 1e-9));
}

static void test_grid_target_edges_and_normalization(void) {
  const double p60 = 1000.0 / 60.0;
  CHECK(mb_frame_pace_grid_target_ms(NAN, p60, 3, 1, 100.0, p60) == -1.0);
  CHECK(mb_frame_pace_grid_target_ms(100.0, NAN, 3, 1, 100.0, p60) == -1.0);
  CHECK(mb_frame_pace_grid_target_ms(100.0, p60, 1, 1, 100.0, p60) == -1.0);
  CHECK(mb_frame_pace_grid_target_ms(100.0, p60, 3, 0, 100.0, p60) == -1.0);
  CHECK(mb_frame_pace_grid_target_ms(100.0, p60, 3, 1, NAN, p60) == -1.0);
  CHECK(mb_frame_pace_grid_target_ms(100.0, p60, 3, 1, 100.0, 0.0) == -1.0);

  // timer_margin_ms bounds
  CHECK(mb_frame_pace_timer_margin_ms(NAN) == 0.0);
  CHECK(mb_frame_pace_timer_margin_ms(0.0) == 0.0);
  CHECK(mb_frame_pace_timer_margin_ms(-16.0) == 0.0);
  CHECK(approx(mb_frame_pace_timer_margin_ms(p60), 0.25, 1e-9));
  CHECK(approx(mb_frame_pace_timer_margin_ms(1000.0 / 240.0), (1000.0 / 240.0) * 0.05, 1e-9));

  // qpcVBlank in past by 5 beats vs in future by 4 beats must normalize to identical exact target beat
  double base_vb = 1000.0;
  double begins = base_vb + 1.2;
  double t_exact = mb_frame_pace_grid_target_ms(begins, p60, 3, 1, base_vb, p60);
  double t_past = mb_frame_pace_grid_target_ms(begins, p60, 3, 1, base_vb - 5.0 * p60, p60);
  double t_future = mb_frame_pace_grid_target_ms(begins, p60, 3, 1, base_vb + 4.0 * p60, p60);
  CHECK(t_exact > begins);
  CHECK(approx(t_exact, base_vb + 3.0 * p60, 1e-9));
  CHECK(approx(t_past, t_exact, 1e-9));
  CHECK(approx(t_future, t_exact, 1e-9));

  // 240Hz with beats=2: refresh_ms = 4.1667ms, period_ms = 8.3333ms, every = 6 -> exact +50.0ms
  double r240 = 1000.0 / 240.0;
  double p240_b2 = r240 * 2.0;
  int every240 = mb_frame_pace_every(1000.0 / p240_b2, 20.0);
  CHECK(every240 == 6);
  double t240 = mb_frame_pace_grid_target_ms(base_vb + 0.5, p240_b2, every240, 1, base_vb - 7.0 * r240, r240);
  CHECK(approx(t240, base_vb + 50.0, 1e-9));
}

// Simulate 20 consecutive Windows frames with +/-1.5ms timer jitter (centered at +1.5ms OS wake overshoot)
// on the idle timer sleep path (sleep_at = target + timer_margin) and verify presented beat delta == every.
static void simulate_windows_20_frames(double refresh_hz, int beats, double req_hz) {
  double refresh_ms = 1000.0 / refresh_hz;
  double period_ms = refresh_ms * (double)beats;
  double top_hz = 1000.0 / period_ms;
  int every = mb_frame_pace_every(top_hz, req_hz);
  CHECK(every > 1);
  double margin = mb_frame_pace_timer_margin_ms(refresh_ms);

  // Deterministic +/-1.5ms jitter pattern around +1.5ms timer wake overshoot -> [0.0, 3.0] ms past sleep_at
  const double jitter[20] = {
      0.0, 1.5, -1.5, 0.8, -0.9, 1.4, -1.2, 0.3, -1.5, 1.5,
      -0.4, 1.1, -1.3, 0.6, -0.7, 1.2, -1.5, 0.9, -0.2, 1.5,
  };
  const int vblank_offset[20] = {
      0, -1, 1, -3, 2, 0, -2, 3, -1, 1,
      -4, 2, 0, -1, 1, -2, 3, 0, -1, 2,
  };

  double begins = 1000.0 * period_ms + 0.5;
  long long prev_present_beat = -1;
  for (int i = 0; i < 20; i++) {
    // DWM presents on the next beat after frame begins (build < period_ms)
    long long present_beat = (long long)floor(begins / period_ms) + 1;
    if (prev_present_beat >= 0) {
      CHECK(present_beat - prev_present_beat == (long long)every);
    }
    prev_present_beat = present_beat;

    double qpc_vblank = (floor(begins / refresh_ms) + (double)vblank_offset[i]) * refresh_ms;
    double target = mb_frame_pace_grid_target_ms(begins, period_ms, every, 1, qpc_vblank, refresh_ms);
    CHECK(target > begins);
    double wake_overshoot = 1.5 + jitter[i];
    begins = target + margin + wake_overshoot;
  }
}

// Dual-window regression: a fast window runs every beat (DwmFlush returns at vb + 0.10ms);
// the slow 20Hz window must hit exact beats 0, 3, 6, 9, 12, 15 (60Hz) and 0, 6, 12, 18, 24 (120Hz).
static void simulate_windows_dual_window(double refresh_hz, double req_hz, const int *expected_beats, int count) {
  double refresh_ms = 1000.0 / refresh_hz;
  double period_ms = refresh_ms;
  int every = mb_frame_pace_every(refresh_hz, req_hz);
  double paced_at = -1.0;
  int fired_count = 0;
  for (int beat = 0; beat <= expected_beats[count - 1]; beat++) {
    double vb = (double)beat * period_ms;
    double now = vb + 0.10;  // fast window DwmFlush returns 0.10ms after vblank
    int draw_slow = (beat == 0) || (paced_at >= 0.0 && now >= paced_at);
    if (draw_slow) {
      CHECK(fired_count < count);
      if (fired_count < count) CHECK(beat == expected_beats[fired_count]);
      fired_count++;
      paced_at = mb_frame_pace_grid_target_ms(now, period_ms, every, 1, vb, refresh_ms);
      CHECK(paced_at > now);
    }
  }
  CHECK(fired_count == count);
}

static void test_clamp_wait_ms(void) {
  CHECK(mb_frame_pace_clamp_wait_ms(NAN, 86400000.0) == 0.0);
  CHECK(mb_frame_pace_clamp_wait_ms(INFINITY, 86400000.0) == 0.0);
  CHECK(mb_frame_pace_clamp_wait_ms(-INFINITY, 86400000.0) == 0.0);
  CHECK(mb_frame_pace_clamp_wait_ms(-10.0, 86400000.0) == 0.0);
  CHECK(mb_frame_pace_clamp_wait_ms(0.0, 86400000.0) == 0.0);
  CHECK(mb_frame_pace_clamp_wait_ms(50.0, NAN) == 0.0);
  CHECK(mb_frame_pace_clamp_wait_ms(50.0, 0.0) == 0.0);
  CHECK(approx(mb_frame_pace_clamp_wait_ms(49.5, 86400000.0), 49.5, 1e-9));
  CHECK(approx(mb_frame_pace_clamp_wait_ms(1e18, 86400000.0), 86400000.0, 1e-9));
}

int main(void) {
  test_every_edges();
  test_tick_wake_ms();
  test_grid_target_edges_and_normalization();
  simulate_windows_20_frames(60.0, 1, 20.0);
  simulate_windows_20_frames(120.0, 1, 20.0);
  simulate_windows_20_frames(144.0, 1, 20.0);
  simulate_windows_20_frames(165.0, 1, 20.0);
  simulate_windows_20_frames(240.0, 2, 20.0);
  const int dual60[] = {0, 3, 6, 9, 12, 15};
  const int dual120[] = {0, 6, 12, 18, 24};
  simulate_windows_dual_window(60.0, 20.0, dual60, 6);
  simulate_windows_dual_window(120.0, 20.0, dual120, 5);
  test_clamp_wait_ms();
  if (failures > 0) {
    fprintf(stderr, "frame_pace_test: %d failures\n", failures);
    return 1;
  }
  printf("frame_pace_test: all checks passed\n");
  return 0;
}
