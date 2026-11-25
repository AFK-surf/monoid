// Shared host frame-pacing helpers (C/C++ header-only, matching frame_late.h).
// Computes integer refresh-cadence divisors and next wake targets for both
// tick-quantized hosts (GTK frame clock) and direct-draw hosts (Windows DWM).
#pragma once

#include <math.h>

// Integer cadence divisor: how many display periods between paced frames (1 = unpaced).
static inline int mb_frame_pace_every(double top_hz, double req_hz) {
  if (!isfinite(top_hz) || !isfinite(req_hz) || top_hz <= 0.0 || top_hz > 1000.0 || req_hz <= 0.0) return 1;
  if (req_hz <= top_hz / 1000.0) return 1000;
  double ratio = top_hz / req_hz;
  if (!isfinite(ratio) || ratio < 1.5) return 1;
  if (ratio > 1000.0) ratio = 1000.0;
  int every = (int)llround(ratio);
  return every > 1 ? every : 1;
}

// Wake delay (ms) for tick-quantized hosts (e.g. Linux GTK frame clock):
// wakes half a period before the target refresh so the tick callback catches the exact slot.
static inline double mb_frame_pace_tick_wake_ms(double period_ms, int every) {
  if (!isfinite(period_ms) || period_ms <= 0.0 || every <= 1) return 0.0;
  return ((double)every - 0.5) * period_ms;
}

// Small positive sleep margin (ms) added ONLY when programming an idle OS wait timer so the wake
// lands just past the target vblank beat without delaying active dual-window DwmFlush readiness checks.
static inline double mb_frame_pace_timer_margin_ms(double refresh_ms) {
  if (!isfinite(refresh_ms) || refresh_ms <= 0.0) return 0.0;
  double margin = refresh_ms * 0.05;
  return margin > 0.25 ? 0.25 : margin;
}

// Exact logical target beat (ms) for direct-draw hosts (Windows: DwmFlush waits after submission).
// Normalizes vblank_ms to the latest vblank <= begins_ms and returns vb + every * period_ms.
// Note: period_ms already includes mb_frame_beats().
// Returns -1.0 when inputs are invalid or the target is not in the future (caller falls back to immediate frame).
static inline double mb_frame_pace_grid_target_ms(double begins_ms, double period_ms, int every, int has_vblank,
                                                  double vblank_ms, double refresh_ms) {
  if (!isfinite(begins_ms) || !isfinite(period_ms) || period_ms <= 0.0 || every <= 1 || !has_vblank ||
      !isfinite(vblank_ms) || !isfinite(refresh_ms) || refresh_ms <= 0.0)
    return -1.0;
  double k = floor((begins_ms - vblank_ms) / refresh_ms);
  double vb = vblank_ms + k * refresh_ms;
  double target = vb + (double)every * period_ms;
  if (!isfinite(target) || target <= begins_ms) return -1.0;
  return target;
}

// Clamps a remaining wait duration (ms) safely into [0.0, max_ms] (guards NaN/Inf/negative/overflow).
static inline double mb_frame_pace_clamp_wait_ms(double rem_ms, double max_ms) {
  if (!isfinite(rem_ms) || rem_ms <= 0.0 || !isfinite(max_ms) || max_ms <= 0.0) return 0.0;
  return rem_ms > max_ms ? max_ms : rem_ms;
}
