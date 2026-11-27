// src/host/win_render.cpp's D3D11 timestamp query ring and dropped-frame counting tests on Windows:
//   cl.exe -nologo -EHsc -W3 -WX -D_CRT_SECURE_NO_WARNINGS -Isrc/host scripts/win_gpu_test.cpp \
//     -Foout/gpu/ -Feout/gpu/win_gpu_test.exe \
//     -link d3d11.lib d3dcompiler.lib dcomp.lib dwmapi.lib gdi32.lib user32.lib windowscodecs.lib ole32.lib
//   out/gpu/win_gpu_test.exe
// Verifies:
// 1. Non-blocking 4-slot D3D11 timestamp disjoint query ring produces valid GPU ms (or degrades cleanly on WARP)
//    and recycles slots across multiple frames and gpu_q_free() without leaking or stalling.
// 2. win_count_dropped_step() accurately counts drops during continuous animation, ignores idle pauses
//    (>= 2.5 * display_period between the samples' sync times), counts in frames of `beats` refreshes (240Hz/360Hz
//    paced to 120fps), clamps spikes to MB_WIN_DROPPED_CLAMP, and guards non-monotonic counters and missing times.
#define MB_NO_MOONBIT_H 1
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <float.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef const wchar_t *moonbit_string_t;
typedef uint8_t *moonbit_bytes_t;
static size_t test_mb_len = 0;
static size_t Moonbit_array_length(moonbit_bytes_t) { return test_mb_len; }

extern "C" {
const wchar_t *mb_win_env(const wchar_t *) { return NULL; }
const wchar_t *mb_win_app_id(void) { return L""; }
void mb_host_request_frame(void) {}
void *mb_image_srv(int) { return NULL; }
uint64_t mb_image_generation(void) { return 0; }
uint64_t mb_image_free_generation(void) { return 0; }
int32_t mb_atlas_gen_now(void) { return 0; }
void *mb_stream_srv(int) { return NULL; }
void mb_text_set_scale(double) {}
int mb_views_count(void) { return 0; }
void mb_views_draw_under(uint8_t *, int, int, double) {}
double mb_app_scale(void) { return 1.0; }
}

#include "win_render.cpp"
#include "frame_late.h"
#include "frame_pace.h"

static int failed = 0;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      printf("%s:%d: failed: %s\n", __FILE__, __LINE__, #c);             \
      fflush(stdout);                                                    \
      failed = 1;                                                        \
    }                                                                    \
  } while (0)

static void fill_rect_instances(double *inst, int count) {
  memset(inst, 0, (size_t)count * MB_INST * sizeof(double));
  for (int i = 0; i < count; i++) {
    double *p = inst + (size_t)i * MB_INST;
    p[0] = (double)((i % 16) * 8);
    p[1] = (double)((i / 16) * 8);
    p[2] = 8.0;
    p[3] = 8.0;
    p[8] = 0.2;
    p[9] = 0.5;
    p[10] = 0.8;
    p[11] = 1.0;
    p[16] = -1e9;
    p[17] = -1e9;
    p[18] = 1e9;
    p[19] = 1e9;
  }
}

static void test_dropped_step_logic(void) {
  const int64_t freq = 10000000;  // 10 MHz QPC (10000 ticks = 1 ms)
  const double p60 = 1000.0 / 60.0;
  const double p120 = 1000.0 / 120.0;

  // 1. Continuous 60Hz, drops, idle >= 2.5*period, clamp, non-monotonic QPC, missing time.
  WinDropStats st = {};
  CHECK(win_stats_step(&st, 1, 0, 10, 100, 100000, freq, p60, 1) == 0);  // first sample
  CHECK(win_stats_step(&st, 1, 0, 11, 101, 266700, freq, p60, 1) == 0);  // normal 60Hz
  CHECK(win_stats_step(&st, 1, 0, 12, 104, 599700, freq, p60, 1) == 2);  // 2 refreshes missed
  CHECK(win_stats_step(&st, 1, 0, 13, 108, 1099700, freq, p60, 1) == 0); // idle 50ms >= 2.5*16.67ms
  CHECK(win_stats_step(&st, 1, 0, 14, 158, 1299700, freq, p60, 1) == MB_WIN_DROPPED_CLAMP);
  CHECK(win_stats_step(&st, 1, 0, 15, 162, 1200000, freq, p60, 1) == 0); // non-monotonic QPC
  CHECK(win_stats_step(&st, 1, 0, 15, 165, 1400000, freq, p60, 1) == 0); // duplicate PresentCount

  // 2. 120Hz / 240Hz (beats=2) / 360Hz (beats=3).
  memset(&st, 0, sizeof st);
  CHECK(win_stats_step(&st, 1, 0, 1, 10, 100000, freq, p120, 2) == 0);
  CHECK(win_stats_step(&st, 1, 0, 2, 12, 183300, freq, p120, 2) == 0);   // normal 240Hz->120fps
  CHECK(win_stats_step(&st, 1, 0, 3, 15, 225000, freq, p120, 2) == 0);   // 1-beat phase jitter
  CHECK(win_stats_step(&st, 1, 0, 4, 19, 391700, freq, p120, 2) == 1);   // 1 frame dropped
  CHECK(win_stats_step(&st, 1, 0, 5, 25, 558400, freq, p120, 2) == 2);   // 2 frames dropped
  memset(&st, 0, sizeof st);
  CHECK(win_stats_step(&st, 1, 0, 1, 10, 100000, freq, p120, 3) == 0);
  CHECK(win_stats_step(&st, 1, 0, 2, 13, 183300, freq, p120, 3) == 0);
  CHECK(win_stats_step(&st, 1, 0, 3, 19, 350000, freq, p120, 3) == 1);

  // 3. Old-segment lagging sample preserved (101->102 counts!), cross-gap (102->103) suppressed, new-segment (103->104) counts.
  memset(&st, 0, sizeof st);
  CHECK(win_stats_step(&st, 1, 0, 101, 500, 100000, freq, p60, 1) == 0);
  st.gap_owed = 1;  // idle gap after submitting 102
  win_stats_on_present(&st, 1, 1, 103);  // new segment starts at 103
  CHECK(win_stats_step(&st, 1, 0, 102, 503, 433000, freq, p60, 1) == 2);  // lagging 101->102 real drop NOT lost!
  CHECK(win_stats_step(&st, 1, 0, 103, 508, 633000, freq, p60, 1) == 0);  // cross-gap 102->103 suppressed!
  CHECK(win_stats_step(&st, 1, 0, 104, 510, 966000, freq, p60, 1) == 1);  // new segment 103->104 real drop counts!

  // 4. Lagging jump sequence 97 -> 97 -> 99 -> 101 -> 102 with gap boundary 100.
  memset(&st, 0, sizeof st);
  st.gap_owed = 1;
  win_stats_on_present(&st, 1, 1, 100);
  CHECK(win_stats_step(&st, 1, 0, 97, 500, 100000, freq, p60, 1) == 0);
  CHECK(win_stats_step(&st, 1, 0, 97, 500, 100000, freq, p60, 1) == 0);
  CHECK(win_stats_step(&st, 1, 0, 99, 502, 300000, freq, p60, 1) == 0);
  CHECK(win_stats_step(&st, 1, 0, 101, 508, 500000, freq, p60, 1) == 0);  // crosses 100 -> suppressed
  CHECK(win_stats_step(&st, 1, 0, 102, 511, 833000, freq, p60, 1) == 2);  // post-gap 101->102 counts 2

  // 5. 32-bit wrap-around through production win_stats_step: 0xFFFFFFFF -> 0 must NOT be dropped as invalid.
  memset(&st, 0, sizeof st);
  CHECK(win_stats_step(&st, 1, 0, 0xFFFFFFFFu, 0xFFFFFFFEu, 100000, freq, p60, 1) == 0);
  CHECK(win_stats_step(&st, 1, 0, 0x00000000u, 0x00000001u, 300000, freq, p60, 1) == 2);

  // 6. DISJOINT, OCCLUDED, GetLastPresentCount failure -> unknown_until sealing, and gap_starts overflow recovery.
  memset(&st, 0, sizeof st);
  CHECK(win_stats_step(&st, 1, 0, 50, 100, 100000, freq, p60, 1) == 0);
  st.gap_owed = 1;
  win_stats_on_present(&st, 1, 0, 0);  // GetLastPresentCount failed -> gap_unknown_open=1
  // Next present seals unknown gap at pc=52: lagging 50->51 and 51->52 must be suppressed, then 52->53 counts!
  win_stats_on_present(&st, 1, 1, 52);
  CHECK(win_stats_step(&st, 1, 0, 51, 104, 300000, freq, p60, 1) == 0);
  CHECK(win_stats_step(&st, 1, 0, 52, 108, 500000, freq, p60, 1) == 0);
  CHECK(win_stats_step(&st, 1, 0, 53, 111, 800000, freq, p60, 1) == 2);
  // OCCLUDED & DISJOINT reset history and open unknown gap.
  win_stats_on_present(&st, 0, 0, 0);
  CHECK(st.has_frame_stats == 0 && st.gap_unknown_open == 1);
  win_stats_on_present(&st, 1, 1, 54);
  CHECK(win_stats_step(&st, 1, 0, 54, 112, 900000, freq, p60, 1) == 0);
  CHECK(win_stats_step(&st, 1, 1, 55, 116, 1100000, freq, p60, 1) == 0);  // DISJOINT
  CHECK(st.has_frame_stats == 0 && st.gap_unknown_open == 1);

  // 6b. 5 consecutive gap_owed calls overflow gap_starts (last pc=120): suppressed up to 120, then 120->121 recovers!
  memset(&st, 0, sizeof st);
  CHECK(win_stats_step(&st, 1, 0, 100, 200, 100000, freq, p60, 1) == 0);
  UINT gap_pcs[5] = {104, 108, 112, 116, 120};
  for (int i = 0; i < 5; i++) {
    st.gap_owed = 1;
    win_stats_on_present(&st, 1, 1, gap_pcs[i]);
  }
  CHECK(win_stats_step(&st, 1, 0, 120, 230, 300000, freq, p60, 1) == 0);  // crosses unknown_until=120 -> 0
  CHECK(win_stats_step(&st, 1, 0, 121, 233, 600000, freq, p60, 1) == 2);  // post-overflow 120->121 recovers!

  // 6c. DISJOINT recovery landing right on 32-bit wrap pc == 0: cold sample 0 is accepted and 0->1 counts drops!
  memset(&st, 0, sizeof st);
  CHECK(win_stats_step(&st, 1, 1, 0xFFFFFFFFu, 100, 100000, freq, p60, 1) == 0);  // DISJOINT
  win_stats_on_present(&st, 1, 1, 0u);  // seals unknown_until == 0
  CHECK(win_stats_step(&st, 1, 0, 0u, 105, 200000, freq, p60, 1) == 0);
  CHECK(st.has_frame_stats == 1 && st.has_unknown_until == 0);
  CHECK(win_stats_step(&st, 1, 0, 1u, 108, 500000, freq, p60, 1) == 2);

  // 7. Dual-window interleaved reporting + secondary window close/reopen: mb_host_frames_dropped() stays monotonic.
  present_dropped_total = 0;
  render_win_fresh(&render_wins[0]);
  render_win_fresh(&render_wins[1]);
  win_stats_on_present(&render_wins[0].drop_stats, 1, 1, 1);
  win_stats_on_present(&render_wins[1].drop_stats, 1, 1, 1);
  present_dropped_total += win_stats_step(&render_wins[0].drop_stats, 1, 0, 1, 10, 100000, freq, p60, 1);
  present_dropped_total += win_stats_step(&render_wins[1].drop_stats, 1, 0, 1, 20, 100000, freq, p60, 1);
  present_dropped_total += win_stats_step(&render_wins[0].drop_stats, 1, 0, 2, 12, 300000, freq, p60, 1);  // +1
  present_dropped_total += win_stats_step(&render_wins[1].drop_stats, 1, 0, 2, 23, 300000, freq, p60, 1);  // +2
  CHECK(mb_host_frames_dropped() == 3);
  // Close & reopen window 1: total must NOT regress
  render_win_fresh(&render_wins[1]);
  CHECK(mb_host_frames_dropped() == 3);
  present_dropped_total = 0;
  render_win_fresh(&render_wins[0]);
  render_win_fresh(&render_wins[1]);
}

static void test_frame_late_logic(void) {
  const double p60 = 1000.0 / 60.0;
  // Multi-window independent last_begin: window A continuous late by 1 beat, window B fresh/idle.
  double win_a_last = -1.0, win_b_last = -1.0;
  CHECK(mb_frame_late_from_begin(win_a_last, 100.0, p60, 0) == 0.0);
  win_a_last = mb_frame_late_next(1, 100.0);
  // Window B draws while idle (want_next = 0) -> does not affect window A.
  CHECK(mb_frame_late_from_begin(win_b_last, 105.0, p60, 0) == 0.0);
  win_b_last = mb_frame_late_next(0, 105.0);
  CHECK(win_b_last == -1.0);
  // Window A's next continuous frame arrives 33.33ms later (1 beat late) -> late > 0.
  double late_a = mb_frame_late_from_begin(win_a_last, 133.333, p60, 0);
  CHECK(late_a > 15.0 && late_a < 18.0);
  // Settle gap: window A stops asking for next app frame (want_next = 0), 100ms later next app frame has frame_late == 0.
  win_a_last = mb_frame_late_next(0, 133.333);
  CHECK(win_a_last == -1.0);
  CHECK(mb_frame_late_from_begin(win_a_last, 233.333, p60, 0) == 0.0);
  // Scripted / away always 0.
  CHECK(mb_frame_late_from_begin(100.0, 200.0, p60, 1) == 0.0);
  // Target-based helper (iOS).
  CHECK(mb_frame_late_from_target(-1.0, 200.0) == 0.0);
  CHECK(mb_frame_late_from_target(100.0, 100.0) == 0.0);
  CHECK(mb_frame_late_from_target(100.0, 116.67) > 16.0);
}

static void test_frame_pace_logic(void) {
  const double p60 = 1000.0 / 60.0;
  CHECK(mb_frame_pace_every(60.0, 20.0) == 3);
  CHECK(mb_frame_pace_every(120.0, 20.0) == 6);
  CHECK(mb_frame_pace_every(240.0 / 2.0, 20.0) == 6);
  CHECK(mb_frame_pace_every(120.0, DBL_MIN) == 1000);
  CHECK(mb_frame_pace_every(NAN, 20.0) == 1);
  CHECK(mb_frame_pace_every(60.0, 0.0) == 1);
  CHECK(mb_frame_pace_timer_margin_ms(p60) == 0.25);
  CHECK(mb_frame_pace_clamp_wait_ms(NAN, 86400000.0) == 0.0);
  CHECK(mb_frame_pace_clamp_wait_ms(1e15, 86400000.0) == 86400000.0);
  double t0 = mb_frame_pace_grid_target_ms(1001.0, p60, 3, 1, 1000.0, p60);
  double t_past = mb_frame_pace_grid_target_ms(1001.0, p60, 3, 1, 1000.0 - 4.0 * p60, p60);
  double t_future = mb_frame_pace_grid_target_ms(1001.0, p60, 3, 1, 1000.0 + 3.0 * p60, p60);
  CHECK(t0 > 1001.0 && fabs(t0 - (1000.0 + 3.0 * p60)) < 1e-6 && fabs(t0 - t_past) < 1e-6 && fabs(t0 - t_future) < 1e-6);
}

static void fill_p0_rect(double *p, double x, double y, double w, double h, double kind, double r, double g, double b,
                         double a, double grp) {
  memset(p, 0, MB_INST * sizeof(double));
  p[0] = x;
  p[1] = y;
  p[2] = w;
  p[3] = h;
  p[5] = kind;
  p[8] = r;
  p[9] = g;
  p[10] = b;
  p[11] = a;
  p[16] = -1e9;
  p[17] = -1e9;
  p[18] = 1e9;
  p[19] = 1e9;
  p[20] = grp;
}

static int read_offscreen_pixel_rgb(int px, int py, uint8_t rgb[3]) {
  if (!dev || !ctx || !off_target) return 0;
  D3D11_TEXTURE2D_DESC td = {};
  off_target->GetDesc(&td);
  td.Usage = D3D11_USAGE_STAGING;
  td.BindFlags = 0;
  td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  td.MiscFlags = 0;
  ID3D11Texture2D *staging = NULL;
  if (FAILED(dev->CreateTexture2D(&td, NULL, &staging))) return 0;
  ctx->CopyResource(staging, off_target);
  D3D11_MAPPED_SUBRESOURCE m = {};
  int ok = 0;
  if (SUCCEEDED(ctx->Map(staging, 0, D3D11_MAP_READ, 0, &m))) {
    const uint8_t *p = (const uint8_t *)m.pData + (size_t)py * (size_t)m.RowPitch + (size_t)px * 4u;
    rgb[0] = p[2];  // R (off_target is DXGI_FORMAT_B8G8R8A8_UNORM)
    rgb[1] = p[1];  // G
    rgb[2] = p[0];  // B
    ctx->Unmap(staging, 0);
    ok = 1;
  }
  staging->Release();
  return ok;
}

static int read_ad_bright_t(double *out_t, uint8_t *out_latch = NULL) {
  if (!dev || !ctx || !rw || !rw->ad_tex[rw->ad_cur].t) return 0;
  ID3D11Texture2D *src = rw->ad_tex[rw->ad_cur].t;
  D3D11_TEXTURE2D_DESC td = {};
  src->GetDesc(&td);
  td.Usage = D3D11_USAGE_STAGING;
  td.BindFlags = 0;
  td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  td.MiscFlags = 0;
  ID3D11Texture2D *staging = NULL;
  if (FAILED(dev->CreateTexture2D(&td, NULL, &staging))) return 0;
  ctx->CopyResource(staging, src);
  D3D11_MAPPED_SUBRESOURCE m = {};
  int ok = 0;
  if (SUCCEEDED(ctx->Map(staging, 0, D3D11_MAP_READ, 0, &m))) {
    const uint8_t *p = (const uint8_t *)m.pData;
    *out_t = ((double)p[0] * 256.0 + (double)p[1]) / 65535.0;
    if (out_latch) *out_latch = p[2];
    ctx->Unmap(staging, 0);
    ok = 1;
  }
  staging->Release();
  return ok;
}

static uint8_t *render_rgba_pixels_of(const double *inst, int count, double r, double g, double b, double scale, int w, int h) {
  size_t bytes = (size_t)w * (size_t)h * 4u;
  uint8_t *buf = (uint8_t *)malloc(bytes);
  if (!buf) return NULL;
  test_mb_len = bytes;
  int ok = mb_render_pixels_of(inst, count, r, g, b, scale, w, h, buf);
  test_mb_len = 0;
  if (!ok) {
    free(buf);
    return NULL;
  }
  return buf;
}

// A shot's pixels for glass_reflect_cases.h, every capture made anew before it.
static uint8_t *gr_pixels(const double *inst, int n, double r, double g, double b, int w, int h) {
  return render_rgba_pixels_of(inst, n, r, g, b, 2.0, w, h);
}
static void gr_free(uint8_t *px) { free(px); }
static void glass_forget(void) { glass_free(); }
#include "glass_reflect_cases.h"

static void test_p0_liquid_glass_vectors(void) {
  struct VecCase {
    const char *name;
    double bg[3];
    double tint[4];
    int is_clear;
    int adaptive;
  };
  static const VecCase cases[7] = {
      {"dark_black", {0.0, 0.0, 0.0}, {32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, 0x67 / 255.0}, 0, 0},
      {"dark_1b1c1f", {27.0 / 255.0, 28.0 / 255.0, 31.0 / 255.0}, {32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, 0x67 / 255.0}, 0, 0},
      {"dark_ad_white", {1.0, 1.0, 1.0}, {32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, 0x67 / 255.0}, 0, 1},
      {"light_blue", {0.0, 136.0 / 255.0, 1.0}, {253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 0x67 / 255.0}, 0, 0},
      {"pure_clear", {0.0, 1.0, 64.0 / 255.0}, {1.0, 1.0, 1.0, 0.0}, 1, 0},
      {"light_d9_blue", {0.0, 0.4, 1.0}, {253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 0xD9 / 255.0}, 0, 0},
      {"light_ff_blue", {0.0, 0.4, 1.0}, {253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 1.0}, 0, 0},
  };
  for (int i = 0; i < 7; i++) {
    double inst[2 * MB_INST];
    fill_p0_rect(inst, 0.0, 0.0, 128.0, 128.0, 0.0, cases[i].bg[0], cases[i].bg[1], cases[i].bg[2], 1.0, 0.0);
    fill_p0_rect(inst + MB_INST, 16.0, 16.0, 96.0, 96.0, 6.0, cases[i].tint[0], cases[i].tint[1], cases[i].tint[2],
                 cases[i].tint[3], (double)(-40 - i));
    inst[MB_INST + 4] = 16.0;
    inst[MB_INST + 6] = 1.0;
    inst[MB_INST + 7] = cases[i].is_clear ? 0.0 : 1.0;
    inst[MB_INST + 12] = 0.0;
    inst[MB_INST + 13] = 4.0;
    inst[MB_INST + 14] = cases[i].adaptive ? -1.0 : 0.0;
    inst[MB_INST + 15] = 1.0;
    uint8_t *px = render_rgba_pixels_of(inst, 2, cases[i].bg[0], cases[i].bg[1], cases[i].bg[2], 1.0, 128, 128);
    CHECK(px != NULL);
    if (!px) continue;
    const uint8_t *rgb = px + ((size_t)64 * 128u + 64u) * 4u;
    printf("win_gpu: p0 %s -> rgb(%u, %u, %u)\n", cases[i].name, rgb[0], rgb[1], rgb[2]);
    if (i == 0) {
      CHECK(rgb[0] >= 30 && rgb[0] <= 38 && rgb[1] >= 30 && rgb[1] <= 38 && rgb[2] >= 30 && rgb[2] <= 38);
    } else if (i == 1) {
      CHECK(rgb[0] >= 53 && rgb[0] <= 63 && rgb[1] >= 54 && rgb[1] <= 64 && rgb[2] >= 57 && rgb[2] <= 67);
    } else if (i == 2) {
      // Dark glass over white: same-polarity densified dark glass (~90, never flipped to light gray 174)
      CHECK(rgb[0] >= 82 && rgb[0] <= 98 && rgb[1] >= 82 && rgb[1] <= 98 && rgb[2] >= 82 && rgb[2] <= 98);
    } else if (i == 3) {
      double mx = (double)(rgb[0] > rgb[1] ? (rgb[0] > rgb[2] ? rgb[0] : rgb[2]) : (rgb[1] > rgb[2] ? rgb[1] : rgb[2]));
      double mn = (double)(rgb[0] < rgb[1] ? (rgb[0] < rgb[2] ? rgb[0] : rgb[2]) : (rgb[1] < rgb[2] ? rgb[1] : rgb[2]));
      double sat = mx > 0.0 ? (mx - mn) / mx : 0.0;
      CHECK(rgb[0] >= 76 && rgb[0] <= 100 && rgb[1] >= 193 && rgb[1] <= 217 && rgb[2] >= 243 && sat >= 0.62);
    } else if (i == 4) {
      CHECK(rgb[0] <= 8 && rgb[1] >= 247 && rgb[2] >= 56 && rgb[2] <= 72);
    } else if (i == 5) {
      CHECK(rgb[0] >= (uint8_t)(0.72 * 255.0 + 0.5) && rgb[1] >= 200 && rgb[2] >= 240);
    } else if (i == 6) {
      CHECK(rgb[0] >= 249 && rgb[1] >= 248 && rgb[2] >= 249);
    }
    free(px);
  }

  // Stateful adaptive transition test 1: Light adaptive (is_dark = 0) 70ms exponential smoothing via submit():
  {
    double inst[2 * MB_INST];
    fill_p0_rect(inst, 0.0, 0.0, 128.0, 128.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0);
    fill_p0_rect(inst + MB_INST, 16.0, 16.0, 96.0, 96.0, 6.0, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0,
                 0x67 / 255.0, -48.0);
    inst[MB_INST + 4] = 16.0;
    inst[MB_INST + 6] = 1.0;
    inst[MB_INST + 7] = 1.0;
    inst[MB_INST + 12] = 0.0;
    inst[MB_INST + 13] = 4.0;
    inst[MB_INST + 14] = -1.0;
    inst[MB_INST + 15] = 1.0;
    glass_free();
    ad_mode = 1;
    ad_cur_dt = 1.0 / 60.0;
    if (rw) {
      rw->ad_frame_serial = 0;
      memset(rw->ad_slots, 0, sizeof rw->ad_slots);
    }
    CHECK(submit(inst, 2, 1.0, 1.0, 1.0) == 1);
    ctx->Flush();
    double frame0_t = -1.0;
    uint8_t rgb0[3] = {0, 0, 0};
    CHECK(read_ad_bright_t(&frame0_t) == 1);
    CHECK(read_offscreen_pixel_rgb(64, 64, rgb0) == 1);
    CHECK(frame0_t <= 0.02);

    // Flip backdrop from white -> black and advance rw->ad_frame_serial++ with deterministic dt = 1/60s.
    fill_p0_rect(inst, 0.0, 0.0, 128.0, 128.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0);
    double mid_frame3_t = -1.0, final_t = -1.0;
    uint8_t final_rgb[3] = {0, 0, 0};
    for (int f = 1; f <= 45; f++) {
      if (rw) rw->ad_frame_serial++;
      ad_cur_dt = 1.0 / 60.0;
      CHECK(submit(inst, 2, 0.0, 0.0, 0.0) == 1);
      ctx->Flush();
      if (f == 3) CHECK(read_ad_bright_t(&mid_frame3_t) == 1);
    }
    CHECK(read_ad_bright_t(&final_t) == 1);
    CHECK(read_offscreen_pixel_rgb(64, 64, final_rgb) == 1);
    printf("win_gpu: stateful_ad_light frame0_t=%.4f mid_frame3_t=%.4f final_t=%.4f rgb0=(%u,%u,%u) final_rgb=(%u,%u,%u)\n",
           frame0_t, mid_frame3_t, final_t, rgb0[0], rgb0[1], rgb0[2], final_rgb[0], final_rgb[1], final_rgb[2]);
    CHECK(fabs(mid_frame3_t - 0.5105) < 0.03);
    CHECK(final_t >= 0.98);
    CHECK(final_rgb[0] < rgb0[0] && final_rgb[1] < rgb0[1] && final_rgb[2] < rgb0[2]);
    ad_cur_dt = 0.0;
    glass_free();
  }

  // Stateful adaptive transition test 2: Dark adaptive (is_dark = 1) same-polarity 70ms easing (latch == 64):
  {
    double inst[2 * MB_INST];
    fill_p0_rect(inst, 0.0, 0.0, 128.0, 128.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0);
    fill_p0_rect(inst + MB_INST, 16.0, 16.0, 96.0, 96.0, 6.0, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, 0x67 / 255.0, -49.0);
    inst[MB_INST + 4] = 16.0;
    inst[MB_INST + 6] = 1.0;
    inst[MB_INST + 7] = 1.0;
    inst[MB_INST + 12] = 0.0;
    inst[MB_INST + 13] = 4.0;
    inst[MB_INST + 14] = -1.0;
    inst[MB_INST + 15] = 1.0;
    glass_free();
    ad_mode = 1;
    ad_cur_dt = 1.0 / 60.0;
    if (rw) {
      rw->ad_frame_serial = 0;
      memset(rw->ad_slots, 0, sizeof rw->ad_slots);
    }
    CHECK(submit(inst, 2, 1.0, 1.0, 1.0) == 1);
    ctx->Flush();
    double frame0_t = -1.0;
    uint8_t latch0 = 0, rgb0[3] = {0, 0, 0};
    CHECK(read_ad_bright_t(&frame0_t, &latch0) == 1);
    CHECK(read_offscreen_pixel_rgb(64, 64, rgb0) == 1);
    CHECK(frame0_t >= 0.98);
    CHECK(latch0 == 64);
    CHECK(rgb0[0] >= 82 && rgb0[0] <= 98 && rgb0[1] >= 82 && rgb0[1] <= 98 && rgb0[2] >= 82 && rgb0[2] <= 98);

    // Flip backdrop from white -> black: frame 1 eases smoothly, converges after 45 frames (t <= 0.02, latch == 64, pixel 30..38).
    fill_p0_rect(inst, 0.0, 0.0, 128.0, 128.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0);
    double frame1_t = -1.0, final_t = -1.0;
    uint8_t latch1 = 0, rgb_end[3] = {0, 0, 0};
    for (int f = 1; f <= 45; f++) {
      if (rw) rw->ad_frame_serial++;
      ad_cur_dt = 1.0 / 60.0;
      CHECK(submit(inst, 2, 0.0, 0.0, 0.0) == 1);
      ctx->Flush();
      if (rw) ad_finalize_frame(rw, 1, rw->ad_frame_serial);
      if (f == 1) CHECK(read_ad_bright_t(&frame1_t, &latch1) == 1);
    }
    CHECK(read_ad_bright_t(&final_t, &latch1) == 1);
    CHECK(read_offscreen_pixel_rgb(64, 64, rgb_end) == 1);
    printf("win_gpu: stateful_ad_dark frame0_t=%.4f latch0=%u frame1_t=%.4f final_t=%.4f latch1=%u rgb_end=(%u,%u,%u) settling=%d\n",
           frame0_t, latch0, frame1_t, final_t, latch1, rgb_end[0], rgb_end[1], rgb_end[2], mb_render_adaptive_settling(0));
    CHECK(frame1_t > 0.50 && frame1_t < 0.95);
    CHECK(final_t <= 0.02);
    CHECK(latch1 == 64);
    CHECK(rgb_end[0] >= 30 && rgb_end[0] <= 38 && rgb_end[1] >= 30 && rgb_end[1] <= 38 && rgb_end[2] >= 30 && rgb_end[2] <= 38);
    CHECK(mb_render_adaptive_settling(0) == 0);
    ad_cur_dt = 0.0;
    glass_free();
  }

  // Stateful adaptive test 3: Clear-invert light adaptive (a[6] = -1.0) opacity (glassFrost / Increase Contrast) suppresses white-on-light flip:
  // (a) Full dark backdrop with 0x67 flips dark (t >= 0.98), raising tint_a to 0.913 on the same slot snaps t <= 0.02 with settling == 0
  //     and keeps dark ink (kind 10) dark on bright frosted light glass;
  // (b) Fresh full dark capsule at 65% frost (0.752) stays light frosted glass + dark ink.
  {
    double inst[3 * MB_INST];
    fill_p0_rect(inst, 0.0, 0.0, 128.0, 128.0, 0.0, 0.08, 0.08, 0.08, 1.0, 0.0);
    fill_p0_rect(inst + MB_INST, 16.0, 16.0, 96.0, 96.0, 6.0, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 0x67 / 255.0, -50.0);
    inst[MB_INST + 4] = 16.0;
    inst[MB_INST + 6] = -1.0;  // clear-invert opt-in
    inst[MB_INST + 7] = 1.0;
    inst[MB_INST + 12] = 0.0;
    inst[MB_INST + 13] = 4.0;
    inst[MB_INST + 14] = -1.0;
    inst[MB_INST + 15] = 1.0;
    fill_p0_rect(inst + 2 * MB_INST, 48.0, 56.0, 32.0, 16.0, 10.0, 0.14, 0.15, 0.17, 1.0, 0.0);
    inst[2 * MB_INST + 4] = 6.0;
    inst[2 * MB_INST + 12] = 0.1; inst[2 * MB_INST + 13] = 0.5;
    inst[2 * MB_INST + 14] = 0.9; inst[2 * MB_INST + 15] = 0.5;
    inst[2 * MB_INST + 21] = 64.0; inst[2 * MB_INST + 22] = 64.0; inst[2 * MB_INST + 23] = 48.0;

    glass_free();
    ad_mode = 1;
    ad_cur_dt = 1.0 / 60.0;
    if (rw) {
      rw->ad_frame_serial = 0;
      memset(rw->ad_slots, 0, sizeof rw->ad_slots);
    }
    CHECK(submit(inst, 3, 0.08, 0.08, 0.08) == 1);
    ctx->Flush();
    double t0 = -1.0;
    uint8_t ink0[3] = {0, 0, 0}, gl0[3] = {0, 0, 0};
    CHECK(read_ad_bright_t(&t0) == 1);
    CHECK(read_offscreen_pixel_rgb(64, 64, ink0) == 1);
    CHECK(read_offscreen_pixel_rgb(32, 32, gl0) == 1);
    CHECK(t0 >= 0.98 && ink0[0] > 180 && gl0[0] < 90);

    // Jump tint_a to 0.913 (95% frost) on the same slot: snaps immediately to light glass + dark ink, settling == 0.
    inst[MB_INST + 11] = 0.913;
    if (rw) rw->ad_frame_serial++;
    ad_cur_dt = 1.0 / 60.0;
    CHECK(submit(inst, 3, 0.08, 0.08, 0.08) == 1);
    ctx->Flush();
    if (rw) ad_finalize_frame(rw, 1, rw->ad_frame_serial);
    double t1 = -1.0;
    uint8_t ink1[3] = {0, 0, 0}, gl1[3] = {0, 0, 0};
    CHECK(read_ad_bright_t(&t1) == 1);
    CHECK(read_offscreen_pixel_rgb(64, 64, ink1) == 1);
    CHECK(read_offscreen_pixel_rgb(32, 32, gl1) == 1);
    printf("win_gpu: light_frost_95 t0=%.3f t1=%.3f ink1=(%u,%u,%u) gl1=(%u,%u,%u) settling=%d\n",
           t0, t1, ink1[0], ink1[1], ink1[2], gl1[0], gl1[1], gl1[2], mb_render_adaptive_settling(0));
    CHECK(t1 <= 0.02 && ink1[0] < 65 && gl1[0] > 215 && mb_render_adaptive_settling(0) == 0);

    // Fresh 65% frost (0.752) capsule over dark backdrop stays light glass + dark ink.
    inst[MB_INST + 11] = 0.752;
    glass_free();
    if (rw) {
      rw->ad_frame_serial = 0;
      memset(rw->ad_slots, 0, sizeof rw->ad_slots);
    }
    CHECK(submit(inst, 3, 0.08, 0.08, 0.08) == 1);
    ctx->Flush();
    double t65 = -1.0;
    uint8_t ink65[3] = {0, 0, 0}, gl65[3] = {0, 0, 0};
    CHECK(read_ad_bright_t(&t65) == 1);
    CHECK(read_offscreen_pixel_rgb(64, 64, ink65) == 1);
    CHECK(read_offscreen_pixel_rgb(32, 32, gl65) == 1);
    printf("win_gpu: light_frost_65 t=%.3f ink=(%u,%u,%u) gl=(%u,%u,%u)\n",
           t65, ink65[0], ink65[1], ink65[2], gl65[0], gl65[1], gl65[2]);
    CHECK(t65 <= 0.02 && ink65[0] < 65 && gl65[0] > 180);
    ad_cur_dt = 0.0;
    glass_free();
  }

  // Opus P1-1 regression: more_contrast dark glass (tint_a = 0.52 -> is_dark == 2) over white must densify (nextT > 0.5)
  {
    double inst[2 * MB_INST];
    fill_p0_rect(inst, 0.0, 0.0, 128.0, 128.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0);
    fill_p0_rect(inst + MB_INST, 16.0, 16.0, 96.0, 96.0, 6.0, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, 0.52, -51.0);
    inst[MB_INST + 4] = 16.0;
    inst[MB_INST + 6] = 1.0;
    inst[MB_INST + 7] = 1.0;
    inst[MB_INST + 12] = 0.0;
    inst[MB_INST + 13] = 4.0;
    inst[MB_INST + 14] = -1.0;
    inst[MB_INST + 15] = 1.0;
    glass_free();
    ad_mode = 1;
    ad_cur_dt = 1.0 / 60.0;
    if (rw) {
      rw->ad_frame_serial = 0;
      memset(rw->ad_slots, 0, sizeof rw->ad_slots);
    }
    CHECK(submit(inst, 2, 1.0, 1.0, 1.0) == 1);
    ctx->Flush();
    double mc_t = -1.0;
    uint8_t mc_latch = 0, mc_rgb[3] = {0, 0, 0};
    CHECK(read_ad_bright_t(&mc_t, &mc_latch) == 1);
    CHECK(read_offscreen_pixel_rgb(64, 64, mc_rgb) == 1);
    printf("win_gpu: dark_more_contrast_white t=%.4f latch=%u rgb=(%u,%u,%u)\n",
           mc_t, mc_latch, mc_rgb[0], mc_rgb[1], mc_rgb[2]);
    CHECK(mc_t > 0.50);
    CHECK(mc_latch == 64);
    CHECK(mc_rgb[0] >= 60 && mc_rgb[0] <= 112);
    ad_cur_dt = 0.0;
    glass_free();
  }
}

static void test_v8_v9_droplet_roi_gates(void) {
  const int VW = 160, VH = 80;
  const int AW3 = VW * 3, AH3 = VH * 3;
  #define W_PX(buf, w, xpx, ypx) ((buf) + ((size_t)(ypx) * (size_t)(w) + (size_t)(xpx)) * 4u)

  // V8a: Slider Dark & Light @ 3x (full dx in [0,6]pt scan + 5-point 3D thickness profile)
  for (int is_light = 0; is_light <= 1; is_light++) {
    double bg = is_light ? 1.0 : 28.0 / 255.0;
    double bg_b = is_light ? 1.0 : 30.0 / 255.0;
    double sl[4 * MB_INST];
    fill_p0_rect(sl, 0, 0, VW, VH, 0, bg, bg, bg_b, 1.0, 0);
    fill_p0_rect(sl + MB_INST, 10, 37, 70, 6, 0, 0.0, 136.0 / 255.0, 1.0, 1.0, 0);
    fill_p0_rect(sl + 2 * MB_INST, 80, 37, 70, 6, 0, 120.0 / 255.0, 120.0 / 255.0, 128.0 / 255.0, 1.0, 0);
    fill_p0_rect(sl + 3 * MB_INST, 51, 21, 58, 38, 6, 1.0, 1.0, 1.0, 0.0, (double)(-50 - is_light));
    sl[3 * MB_INST + 4] = 19.0; sl[3 * MB_INST + 6] = 1.0; sl[3 * MB_INST + 7] = -16.0;
    sl[3 * MB_INST + 12] = 1.0; sl[3 * MB_INST + 13] = 9.0; sl[3 * MB_INST + 15] = 1.0;
    sl[3 * MB_INST + 21] = 9.0;
    uint8_t *px = render_rgba_pixels_of(sl, 4, bg, bg, bg_b, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (!px) continue;
    double max_bh = 0.0, peak_dx = 0.0, h_55 = 0.0;
    double max_gh = 0.0, grey_peak_dx = 0.0, grey_h55 = 0.0;
    for (int i = 0; i <= 18; i++) {
      int x_l = 51 * 3 + i;
      int cnt = 0;
      for (int ypx = 21 * 3; ypx < 59 * 3; ypx++) {
        uint8_t *c = W_PX(px, AW3, x_l, ypx);
        if ((int)c[2] - (int)c[0] > 100) cnt++;
      }
      double hpt = (double)cnt / 3.0;
      double dx_l = ((double)i + 0.5) / 3.0;
      if (hpt > max_bh) { max_bh = hpt; peak_dx = dx_l; }
      if (i == 16) h_55 = hpt;
    }
    uint8_t *bg_ref = W_PX(px, AW3, 80 * 3, 25 * 3);
    double ref_y = 0.2126 * bg_ref[0] + 0.7152 * bg_ref[1] + 0.0722 * bg_ref[2];
    for (int i = 0; i <= 18; i++) {
      int x_r = 109 * 3 - 1 - i;
      int cnt = 0;
      for (int ypx = 33 * 3; ypx < 47 * 3; ypx++) {
        uint8_t *c = W_PX(px, AW3, x_r, ypx);
        double cy = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
        if (is_light ? (cy < ref_y - 70.0) : (cy > ref_y + 20.0)) cnt++;
      }
      double hpt = (double)cnt / 3.0;
      double dx_r = ((double)i + 0.5) / 3.0;
      if (hpt > max_gh) { max_gh = hpt; grey_peak_dx = dx_r; }
      if (i == 16) grey_h55 = hpt;
    }
    uint8_t *c_l = W_PX(px, AW3, (int)(79.3 * 3), 40 * 3);
    uint8_t *c_r = W_PX(px, AW3, (int)(80.7 * 3), 40 * 3);
    uint8_t *c_top = W_PX(px, AW3, 60 * 3, 25 * 3);
    uint8_t *c_bot = W_PX(px, AW3, 60 * 3, 55 * 3);
    uint8_t *t0 = W_PX(px, AW3, 80 * 3, 21 * 3);
    uint8_t *t1 = W_PX(px, AW3, 80 * 3, 21 * 3 + 2);
    uint8_t *t2 = W_PX(px, AW3, 80 * 3, 23 * 3);
    uint8_t *t9 = W_PX(px, AW3, 80 * 3, 30 * 3);
    uint8_t *t24 = W_PX(px, AW3, 80 * 3, 45 * 3);
    double y0 = 0.2126 * t0[0] + 0.7152 * t0[1] + 0.0722 * t0[2];
    double y1 = 0.2126 * t1[0] + 0.7152 * t1[1] + 0.0722 * t1[2];
    double y2 = 0.2126 * t2[0] + 0.7152 * t2[1] + 0.0722 * t2[2];
    double y9 = 0.2126 * t9[0] + 0.7152 * t9[1] + 0.0722 * t9[2];
    double y24 = 0.2126 * t24[0] + 0.7152 * t24[1] + 0.0722 * t24[2];
    printf("win_gpu: v8_slider(%s) blue_peak=%.2f@dx=%.2f blue_h55=%.2f grey_peak=%.2f@dx=%.2f grey_h55=%.2f prof5=(%.0f,%.0f,%.0f,%.0f,%.0f)\n",
           is_light ? "light" : "dark", max_bh, peak_dx, h_55, max_gh, grey_peak_dx, grey_h55, y0, y1, y2, y9, y24);
    CHECK(max_bh >= 9.5 && max_bh <= 12.5);
    CHECK(peak_dx >= 0.33 && peak_dx <= 1.50);
    CHECK(h_55 >= 5.6 && h_55 <= 6.4);
    CHECK(max_gh >= 9.5 && max_gh <= 12.5);
    CHECK(grey_peak_dx >= 0.33 && grey_peak_dx <= 1.50);
    CHECK(grey_h55 >= 5.6 && grey_h55 <= 6.4);
    CHECK((int)c_l[2] - (int)c_l[0] > 100 && (int)c_r[2] - (int)c_r[0] < 20);
    CHECK((int)c_top[2] - (int)c_top[0] < 20 && (int)c_bot[2] - (int)c_bot[0] < 20);
    CHECK(y1 > y0 && y2 > y9 && y9 < y24);
    free(px);
  }

  // V8a2: Horizontal-stripe vertical monotonicity (zero folding)
  {
    double st[42 * MB_INST];
    fill_p0_rect(st, 0, 0, VW, VH, 0, 0.0, 0.0, 0.0, 1.0, 0);
    for (int i = 0; i < 40; i++) {
      double v = (i - 12.0) / 16.0;
      if (v < 0.0) v = 0.0;
      if (v > 1.0) v = 1.0;
      fill_p0_rect(st + (i + 1) * MB_INST, 0, 20 + i, VW, 1, 0, 1.0 - v, 0.0, v, 1.0, 0);
    }
    fill_p0_rect(st + 41 * MB_INST, 51, 21, 58, 38, 6, 1.0, 1.0, 1.0, 0.0, -52.0);
    st[41 * MB_INST + 4] = 19.0; st[41 * MB_INST + 6] = 1.0; st[41 * MB_INST + 7] = -16.0;
    st[41 * MB_INST + 12] = 1.0; st[41 * MB_INST + 13] = 9.0; st[41 * MB_INST + 15] = 1.0; st[41 * MB_INST + 21] = 9.0;
    uint8_t *px = render_rgba_pixels_of(st, 42, 0.0, 0.0, 0.0, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (px) {
      int xpx = (int)(51.85 * 3);
      int prev = -1000, mono_ok = 1;
      for (int ypx = 36 * 3; ypx <= 44 * 3; ypx++) {
        uint8_t *c = W_PX(px, AW3, xpx, ypx);
        int cur = (int)c[2] - (int)c[0];
        if (prev > -999 && cur < prev - 6) mono_ok = 0;
        prev = cur;
      }
      CHECK(mono_ok);
      free(px);
    }
  }

  // V8b: 124x48pt dropRole=0 magnifier unaffected + Role 0 real zoom (1.18) contact-edge push
  {
    double mg[3 * MB_INST];
    fill_p0_rect(mg, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
    fill_p0_rect(mg + MB_INST, 0, 37, VW, 6, 0, 0.0, 136.0 / 255.0, 1.0, 1.0, 0);
    fill_p0_rect(mg + 2 * MB_INST, 18, 16, 124, 48, 6, 1.0, 1.0, 1.0, 0.0, -53.0);
    mg[2 * MB_INST + 4] = 24.0; mg[2 * MB_INST + 6] = 1.0; mg[2 * MB_INST + 7] = 0.0;
    mg[2 * MB_INST + 12] = 1.0; mg[2 * MB_INST + 13] = 8.0; mg[2 * MB_INST + 15] = 1.0; mg[2 * MB_INST + 21] = 3.0;
    uint8_t *px = render_rgba_pixels_of(mg, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (px) {
      int cnt = 0;
      for (int ypx = 16 * 3; ypx < 64 * 3; ypx++) {
        uint8_t *c = W_PX(px, AW3, 19 * 3, ypx);
        if ((int)c[2] - (int)c[0] > 100) cnt++;
      }
      printf("win_gpu: v8_magnifier_role0 h(1.0)=%.2f\n", (double)cnt / 3.0);
      CHECK((double)cnt / 3.0 < 7.0);
      free(px);
    }
  }
  {
    double zm[3 * MB_INST];
    fill_p0_rect(zm, 0, 0, VW, VH, 0, 1.0, 0.0, 0.0, 1.0, 0);
    fill_p0_rect(zm + MB_INST, 0, 0, 55.2, VH, 0, 0.0, 1.0, 0.0, 1.0, 0);
    fill_p0_rect(zm + 2 * MB_INST, 51, 21, 58, 38, 6, 1.0, 1.0, 1.0, 0.0, -59.0);
    zm[2 * MB_INST + 4] = 19.0; zm[2 * MB_INST + 6] = 1.0; zm[2 * MB_INST + 7] = -0.18;
    zm[2 * MB_INST + 12] = 1.0; zm[2 * MB_INST + 13] = 8.0; zm[2 * MB_INST + 15] = 1.0; zm[2 * MB_INST + 21] = 8.0;
    uint8_t *px = render_rgba_pixels_of(zm, 3, 1.0, 0.0, 0.0, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (px) {
      uint8_t *edge = W_PX(px, AW3, 51 * 3, 40 * 3);
      printf("win_gpu: v8_role0_zoom118_contact rgb=(%u,%u,%u)\n", edge[0], edge[1], edge[2]);
      CHECK((int)edge[1] > (int)edge[0] + 40);
      free(px);
    }
  }

  // V9a: Switch ON @ 3x
  {
    double sw[3 * MB_INST];
    fill_p0_rect(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
    fill_p0_rect(sw + MB_INST, 40, 26, 63, 28, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 1.0, 0);
    sw[MB_INST + 4] = 14.0;
    fill_p0_rect(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, -54.0);
    sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
    sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0; sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0;
    uint8_t *px = render_rgba_pixels_of(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (px) {
      uint8_t *r0 = W_PX(px, AW3, 80 * 3, 21 * 3 + 0);
      uint8_t *r1 = W_PX(px, AW3, 80 * 3, 21 * 3 + 1);
      uint8_t *r2 = W_PX(px, AW3, 80 * 3, 21 * 3 + 2);
      int gr0 = (int)r0[1] - (int)r0[0], gr1 = (int)r1[1] - (int)r1[0], gr2 = (int)r2[1] - (int)r2[0];
      int core_px = 0, first_core_y = -1;
      for (int ypx = 21 * 3 + 2; ypx < 59 * 3; ypx++) {
        uint8_t *c = W_PX(px, AW3, 80 * 3, ypx);
        if ((int)c[1] - (int)c[0] > 60) {
          if (first_core_y < 0) first_core_y = ypx;
          core_px++;
        }
      }
      double moat_top_pt = first_core_y >= 0 ? (double)(first_core_y - (21 * 3 + 2)) / 3.0 : 0.0;
      uint8_t *tip = W_PX(px, AW3, (int)(111.5 * 3), 40 * 3);
      int tip_gr = (int)tip[1] - (int)tip[0];
      printf("win_gpu: v9_switch_on_3x tir=(%d,%d,%d) core=%.2f moat_top=%.2f tip_gr=%d\n",
             gr0, gr1, gr2, (double)core_px / 3.0, moat_top_pt, tip_gr);
      CHECK(gr0 < 15 && gr1 > 60 && gr2 < 15);
      CHECK((double)core_px / 3.0 >= 20.0 && (double)core_px / 3.0 <= 22.5);
      CHECK(moat_top_pt >= 6.5);
      CHECK(tip_gr < 15);
      free(px);
    }
  }

  // V9b: Switch OFF @ 3x + right-cap inward horizontal profile
  {
    double sw[4 * MB_INST];
    fill_p0_rect(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
    fill_p0_rect(sw + MB_INST, 40, 26, 63, 28, 0, 120.0 / 255.0, 120.0 / 255.0, 128.0 / 255.0, 1.0, 0);
    sw[MB_INST + 4] = 14.0;
    fill_p0_rect(sw + 2 * MB_INST, 85.0, 26.0, 2.0, 28.0, 0, 0.0, 136.0 / 255.0, 1.0, 1.0, 0);
    fill_p0_rect(sw + 3 * MB_INST, 30.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, -55.0);
    sw[3 * MB_INST + 4] = 19.2; sw[3 * MB_INST + 6] = 1.0; sw[3 * MB_INST + 7] = -32.0;
    sw[3 * MB_INST + 12] = 1.0; sw[3 * MB_INST + 13] = 9.0; sw[3 * MB_INST + 15] = 1.0; sw[3 * MB_INST + 21] = 9.0;
    uint8_t *px = render_rgba_pixels_of(sw, 4, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (px) {
      uint8_t *core_c = W_PX(px, AW3, 60 * 3, 40 * 3);
      uint8_t *moat_c = W_PX(px, AW3, 60 * 3, 25 * 3);
      uint8_t *h0 = W_PX(px, AW3, 60 * 3, 21 * 3);
      uint8_t *rm = W_PX(px, AW3, 60 * 3, 21 * 3 + 2);
      uint8_t *rcap = W_PX(px, AW3, (int)(88.6 * 3), 40 * 3);
      uint8_t *rtir = W_PX(px, AW3, (int)(89.3 * 3), 40 * 3);
      int rcap_br = (int)rcap[2] - (int)rcap[0];
      int rtir_br = (int)rtir[2] - (int)rtir[0];
      printf("win_gpu: v9_switch_off_3x core=%u moat=%u rim=%u h0=%u rcap_br=%d rtir_br=%d\n",
             core_c[0], moat_c[0], rm[0], h0[0], rcap_br, rtir_br);
      CHECK(core_c[0] > moat_c[0] + 15 && rm[0] > h0[0]);
      CHECK(rcap_br < 20 && rtir_br > 80);
      free(px);
    }
  }

  // V9b2: Switch half-press p = 0.5 / 0.6 / 1.0
  {
    double ps[3] = {0.5, 0.6, 1.0};
    int red_rows[3] = {0, 0, 0};
    for (int pi = 0; pi < 3; pi++) {
      double p = ps[pi];
      double sw[3 * MB_INST];
      fill_p0_rect(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
      fill_p0_rect(sw + MB_INST, 40, 20, 80, 7, 0, 1.0, 0.0, 0.0, 1.0, 0);
      fill_p0_rect(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, (double)(-60 - pi));
      sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
      sw[2 * MB_INST + 12] = p; sw[2 * MB_INST + 13] = 9.0 * p; sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0 * p;
      uint8_t *px = render_rgba_pixels_of(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
      CHECK(px != NULL);
      if (px) {
        for (int ypx = 27 * 3; ypx < 38 * 3; ypx++) {
          uint8_t *c = W_PX(px, AW3, 80 * 3, ypx);
          if ((int)c[0] - (int)c[2] > 80) red_rows[pi]++;
        }
        free(px);
      }
    }
    printf("win_gpu: v9_switch_half_press red_shift_px=(p0.5:%d, p0.6:%d, p1.0:%d)\n",
           red_rows[0], red_rows[1], red_rows[2]);
    CHECK(red_rows[0] >= 4 && red_rows[1] >= red_rows[0] && red_rows[2] > red_rows[1]);
  }

  // V9c: Light Segmented Prism @ 3x (top/bot cyan, left/right amber, dark-stroke text ROI chroma-0 invariance)
  {
    double sg[4 * MB_INST];
    fill_p0_rect(sg, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 1.0, 0);
    fill_p0_rect(sg + MB_INST, 60.0, 34.0, 4.0, 12.0, 0, 20.0 / 255.0, 20.0 / 255.0, 20.0 / 255.0, 1.0, 0);
    fill_p0_rect(sg + 2 * MB_INST, 78.0, 36.0, 22.0, 3.0, 0, 20.0 / 255.0, 20.0 / 255.0, 20.0 / 255.0, 1.0, 0);
    fill_p0_rect(sg + 3 * MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, 0.0, -56.0);
    sg[3 * MB_INST + 4] = 22.5; sg[3 * MB_INST + 6] = 1.0; sg[3 * MB_INST + 7] = -48.0;
    sg[3 * MB_INST + 12] = 1.0; sg[3 * MB_INST + 13] = 9.0; sg[3 * MB_INST + 15] = 1.0;
    sg[3 * MB_INST + 21] = 9.0; sg[3 * MB_INST + 22] = 0.04;
    uint8_t *px = render_rgba_pixels_of(sg, 4, 1.0, 1.0, 1.0, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (px) {
      uint8_t *top = W_PX(px, AW3, 80 * 3, (int)(18.4 * 3));
      uint8_t *bot = W_PX(px, AW3, 80 * 3, (int)(61.6 * 3));
      uint8_t *lft = W_PX(px, AW3, (int)(25.9 * 3), 40 * 3);
      uint8_t *rgt = W_PX(px, AW3, (int)(134.1 * 3), 40 * 3);
      printf("win_gpu: v9_seg_light top B-R=%d bot B-R=%d lft R-B=%d rgt R-B=%d\n",
             (int)top[2] - (int)top[0], (int)bot[2] - (int)bot[0],
             (int)lft[0] - (int)lft[2], (int)rgt[0] - (int)rgt[2]);
      CHECK((int)top[2] - (int)top[0] >= 10);
      CHECK((int)bot[2] - (int)bot[0] >= 10);
      CHECK((int)lft[0] - (int)lft[2] >= 20);
      CHECK((int)rgt[0] - (int)rgt[2] >= 20);
      sg[3 * MB_INST + 20] = -561.0;
      sg[3 * MB_INST + 22] = 0.0;
      uint8_t *px0 = render_rgba_pixels_of(sg, 4, 1.0, 1.0, 1.0, 3.0, AW3, AH3);
      CHECK(px0 != NULL);
      if (px0) {
        int text_max_diff = 0;
        for (int py = 32 * 3; py <= 48 * 3; py++) {
          for (int px_i = 55 * 3; px_i <= 105 * 3; px_i++) {
            uint8_t *a = W_PX(px, AW3, px_i, py);
            uint8_t *b = W_PX(px0, AW3, px_i, py);
            for (int ch = 0; ch < 3; ch++) {
              int df = abs((int)a[ch] - (int)b[ch]);
              if (df > text_max_diff) text_max_diff = df;
            }
          }
        }
        printf("win_gpu: v9_seg_text_roi_diff=%d\n", text_max_diff);
        CHECK(text_max_diff == 0);
        // Role 3 interior 1.00x vertical text scale (12pt = 36px@3x dark stroke, no ~20% compression)
        int seg_stroke_span = 0;
        for (int py = 30 * 3; py <= 50 * 3; py++) {
          uint8_t *sc = W_PX(px, AW3, 62 * 3, py);
          double sl = 0.2126 * sc[0] + 0.7152 * sc[1] + 0.0722 * sc[2];
          if (sl < 160.0) seg_stroke_span++;
        }
        // Role 3 track pinch (+3.0pt outer grey track pulled white at y=25.5pt, grey at y=29.0pt)
        double tp[3 * MB_INST];
        fill_p0_rect(tp, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 1.0, 0);
        fill_p0_rect(tp + MB_INST, 10.0, 24.0, 140.0, 32.0, 0, 190.0 / 255.0, 190.0 / 255.0, 190.0 / 255.0, 1.0, 0);
        fill_p0_rect(tp + 2 * MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, 0.0, -5611.0);
        tp[2 * MB_INST + 4] = 22.5; tp[2 * MB_INST + 6] = 1.0; tp[2 * MB_INST + 7] = -48.0;
        tp[2 * MB_INST + 12] = 1.0; tp[2 * MB_INST + 13] = 9.0; tp[2 * MB_INST + 15] = 1.0;
        tp[2 * MB_INST + 21] = 9.0; tp[2 * MB_INST + 22] = 0.04;
        uint8_t *pxt = render_rgba_pixels_of(tp, 3, 1.0, 1.0, 1.0, 3.0, AW3, AH3);
        CHECK(pxt != NULL);
        if (pxt) {
          uint8_t *po = W_PX(pxt, AW3, 80 * 3, (int)(25.5 * 3));
          uint8_t *pi = W_PX(pxt, AW3, 80 * 3, (int)(29.0 * 3));
          double pinch_out_L = 0.2126 * po[0] + 0.7152 * po[1] + 0.0722 * po[2];
          double pinch_in_L = 0.2126 * pi[0] + 0.7152 * pi[1] + 0.0722 * pi[2];
          printf("win_gpu: v9_seg_scale stroke_span=%dpx pinch_out_L=%.1f pinch_in_L=%.1f\n",
                 seg_stroke_span, pinch_out_L, pinch_in_L);
          CHECK(seg_stroke_span >= 35 && seg_stroke_span <= 37);
          CHECK(pinch_out_L > 240.0 && pinch_in_L < 215.0);
          free(pxt);
        }
        free(px0);
      }
      free(px);
    }
  }

  // V9e: Switch uniform green center + blue-track swap + OFF r9->r4.5 + 5-level press
  {
    double sg[2 * MB_INST];
    fill_p0_rect(sg, 0, 0, VW, VH, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 1.0, 0);
    fill_p0_rect(sg + MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, -562.0);
    sg[MB_INST + 4] = 19.2; sg[MB_INST + 6] = 1.0; sg[MB_INST + 7] = -32.0;
    sg[MB_INST + 12] = 1.0; sg[MB_INST + 13] = 9.0; sg[MB_INST + 15] = 1.0; sg[MB_INST + 21] = 9.0;
    uint8_t *px = render_rgba_pixels_of(sg, 2, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (px) {
      uint8_t *c = W_PX(px, AW3, (int)lround(82.5 * 3), (int)lround(40.2 * 3));
      printf("win_gpu: v9_switch_green_ctr rgb=(%u,%u,%u) exp=(57,218,97)\n", c[0], c[1], c[2]);
      CHECK(abs((int)c[0] - 57) <= 2 && abs((int)c[1] - 218) <= 2 && abs((int)c[2] - 97) <= 2);
      free(px);
    }
    double sb[3 * MB_INST];
    fill_p0_rect(sb, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
    fill_p0_rect(sb + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 0.0, 122.0 / 255.0, 1.0, 1.0, 0);
    sb[MB_INST + 4] = 14.0;
    sb[MB_INST + 36] = 14.0; sb[MB_INST + 37] = 14.0; sb[MB_INST + 38] = 14.0; sb[MB_INST + 39] = 14.0;
    fill_p0_rect(sb + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, -5621.0);
    sb[2 * MB_INST + 4] = 19.2; sb[2 * MB_INST + 6] = 1.0; sb[2 * MB_INST + 7] = -32.0;
    sb[2 * MB_INST + 12] = 1.0; sb[2 * MB_INST + 13] = 9.0; sb[2 * MB_INST + 15] = 1.0; sb[2 * MB_INST + 21] = 9.0;
    uint8_t *pxb = render_rgba_pixels_of(sb, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
    CHECK(pxb != NULL);
    if (pxb) {
      uint8_t *cb = W_PX(pxb, AW3, 80 * 3, 21 * 3 + 1);
      printf("win_gpu: v9_switch_blue_caustic rgb=(%u,%u,%u) B-R=%d\n", cb[0], cb[1], cb[2], (int)cb[2] - (int)cb[0]);
      CHECK((int)cb[2] - (int)cb[0] >= 100 && cb[2] > cb[1]);
      free(pxb);
    }
    int off_moat[2] = {0, 0};
    double refs[2] = {9.0, 4.5};
    for (int ri = 0; ri < 2; ri++) {
      double so[3 * MB_INST];
      fill_p0_rect(so, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
      fill_p0_rect(so + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 120.0 / 255.0, 120.0 / 255.0, 128.0 / 255.0, 1.0, 0);
      so[MB_INST + 4] = 14.0;
      so[MB_INST + 36] = 14.0; so[MB_INST + 37] = 14.0; so[MB_INST + 38] = 14.0; so[MB_INST + 39] = 14.0;
      fill_p0_rect(so + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, (double)(-5622 - ri));
      so[2 * MB_INST + 4] = 19.2; so[2 * MB_INST + 6] = 1.0; so[2 * MB_INST + 7] = -32.0;
      so[2 * MB_INST + 12] = 1.0; so[2 * MB_INST + 13] = 9.0; so[2 * MB_INST + 15] = 1.0; so[2 * MB_INST + 21] = refs[ri];
      uint8_t *pxo = render_rgba_pixels_of(so, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
      CHECK(pxo != NULL);
      if (pxo) {
        int best = 0, cur = 0;
        for (int py = 21 * 3 + 2; py < 40 * 3; py++) {
          uint8_t *c0 = W_PX(pxo, AW3, 80 * 3, py);
          if (c0[0] < 95) { cur++; if (cur > best) best = cur; } else cur = 0;
        }
        off_moat[ri] = best;
        free(pxo);
      }
    }
    printf("win_gpu: v9_switch_off_moat r9=%dpx r4.5=%dpx\n", off_moat[0], off_moat[1]);
    CHECK(off_moat[0] > off_moat[1] && off_moat[1] >= 1);
    double ps[5] = {0.0, 0.25, 0.50, 0.75, 1.0};
    int areas[5] = {0, 0, 0, 0, 0};
    uint8_t *px_rest = NULL;
    for (int pi = 0; pi < 5; pi++) {
      double p = ps[pi];
      double sc5[4 * MB_INST];
      fill_p0_rect(sc5, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
      fill_p0_rect(sc5 + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 1.0, 0);
      sc5[MB_INST + 4] = 14.0;
      sc5[MB_INST + 36] = 14.0; sc5[MB_INST + 37] = 14.0; sc5[MB_INST + 38] = 14.0; sc5[MB_INST + 39] = 14.0;
      double cw = 37.0 * (1.0 + 0.60 * p), ch = 24.0 * (1.0 + 0.60 * p);
      double cx0 = 82.5 - cw * 0.5, cy0 = 40.0 - ch * 0.5;
      double cap_a = 1.0 - 1.8 * p;
      if (cap_a < 0.0) cap_a = 0.0;
      if (cap_a > 1.0) cap_a = 1.0;
      fill_p0_rect(sc5 + 2 * MB_INST, cx0, cy0, cw, ch, 0, 1.0, 1.0, 1.0, cap_a, 0);
      sc5[2 * MB_INST + 4] = ch * 0.5;
      sc5[2 * MB_INST + 36] = ch * 0.5; sc5[2 * MB_INST + 37] = ch * 0.5;
      sc5[2 * MB_INST + 38] = ch * 0.5; sc5[2 * MB_INST + 39] = ch * 0.5;
      int ninst = 3;
      if (p > 0.001) {
        fill_p0_rect(sc5 + 3 * MB_INST, cx0, cy0, cw, ch, 6, 1.0, 1.0, 1.0, 0.0, (double)(-5625 - pi));
        sc5[3 * MB_INST + 4] = ch * 0.5; sc5[3 * MB_INST + 6] = 1.0; sc5[3 * MB_INST + 7] = -32.0;
        sc5[3 * MB_INST + 12] = p; sc5[3 * MB_INST + 13] = 9.0 * p;
        sc5[3 * MB_INST + 15] = p; sc5[3 * MB_INST + 21] = 9.0 * p;
        ninst = 4;
      }
      uint8_t *px5 = render_rgba_pixels_of(sc5, ninst, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
      CHECK(px5 != NULL);
      if (px5) {
        if (pi == 0) {
          px_rest = px5;
          areas[0] = 0;
        } else if (px_rest) {
          int cnt = 0;
          for (int py = 21 * 3; py <= 59 * 3; py += 2) {
            for (int px_i = 53 * 3; px_i <= 112 * 3; px_i += 2) {
              uint8_t *c0 = W_PX(px5, AW3, px_i, py);
              uint8_t *r0 = W_PX(px_rest, AW3, px_i, py);
              int d = abs((int)c0[0] - (int)r0[0]) + abs((int)c0[1] - (int)r0[1]) + abs((int)c0[2] - (int)r0[2]);
              if (d >= 30) cnt++;
            }
          }
          areas[pi] = cnt;
          free(px5);
        } else {
          free(px5);
        }
      }
    }
    free(px_rest);
    printf("win_gpu: v9_switch_5press_delta_area=(%d,%d,%d,%d,%d)\n", areas[0], areas[1], areas[2], areas[3], areas[4]);
    CHECK(areas[0] < areas[1] && areas[1] < areas[2] && areas[2] < areas[3] && areas[3] < areas[4]);
  }

  // V9f: Role 4 Tab monotonic outer meniscus (no fake badge copy from 6.7pt inward; continuous outer lip refraction)
  {
    double tb[4 * MB_INST];
    fill_p0_rect(tb, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
    fill_p0_rect(tb + MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, 0.0, -563.0);
    tb[MB_INST + 4] = 22.5; tb[MB_INST + 6] = 1.0; tb[MB_INST + 7] = -64.0;
    tb[MB_INST + 12] = 1.0; tb[MB_INST + 13] = 9.0; tb[MB_INST + 15] = 1.0; tb[MB_INST + 21] = 9.0;
    uint8_t *px_empty = render_rgba_pixels_of(tb, 2, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
    fill_p0_rect(tb + MB_INST, 127.3, 35.0, 2.0, 10.0, 0, 1.0, 0.55, 0.0, 1.0, 0);
    fill_p0_rect(tb + 2 * MB_INST, 117.0, 56.0, 2.0, 6.0, 0, 1.0, 0.55, 0.0, 1.0, 0);
    fill_p0_rect(tb + 3 * MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, 0.0, -564.0);
    tb[3 * MB_INST + 4] = 22.5; tb[3 * MB_INST + 6] = 1.0; tb[3 * MB_INST + 7] = -64.0;
    tb[3 * MB_INST + 12] = 1.0; tb[3 * MB_INST + 13] = 9.0; tb[3 * MB_INST + 15] = 1.0; tb[3 * MB_INST + 21] = 9.0;
    uint8_t *px_icon = render_rgba_pixels_of(tb, 4, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
    fill_p0_rect(tb + MB_INST, 132.4, 35.0, 1.0, 10.0, 0, 1.0, 0.55, 0.0, 1.0, 0);
    fill_p0_rect(tb + 2 * MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, 0.0, -566.0);
    tb[2 * MB_INST + 4] = 22.5; tb[2 * MB_INST + 6] = 1.0; tb[2 * MB_INST + 7] = -64.0;
    tb[2 * MB_INST + 12] = 1.0; tb[2 * MB_INST + 13] = 9.0; tb[2 * MB_INST + 15] = 1.0; tb[2 * MB_INST + 21] = 9.0;
    uint8_t *px_lip = render_rgba_pixels_of(tb, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
    CHECK(px_empty != NULL && px_icon != NULL && px_lip != NULL);
    if (px_empty && px_icon && px_lip) {
      uint8_t *a_mid = W_PX(px_empty, AW3, 400, 120);
      uint8_t *b_mid = W_PX(px_icon, AW3, 400, 120);
      int ghost_delta = abs((int)b_mid[0] - (int)a_mid[0]) + abs((int)b_mid[1] - (int)a_mid[1]);
      uint8_t *a_out = W_PX(px_empty, AW3, (int)lround(123.2 * 3), (int)lround(58.9 * 3));
      uint8_t *b_out = W_PX(px_icon, AW3, (int)lround(123.2 * 3), (int)lround(58.9 * 3));
      int out_diff = 0;
      for (int ch = 0; ch < 3; ch++) {
        int df = abs((int)b_out[ch] - (int)a_out[ch]);
        if (df > out_diff) out_diff = df;
      }
      uint8_t *a_lip = W_PX(px_empty, AW3, 403, 120);
      uint8_t *c_lip = W_PX(px_lip, AW3, 403, 120);
      int lip_delta = abs((int)c_lip[0] - (int)a_lip[0]) + abs((int)c_lip[1] - (int)a_lip[1]);
      printf("win_gpu: v9_tab_icon_bevel ghost_delta=%d out_diff=%d lip_delta=%d\n", ghost_delta, out_diff, lip_delta);
      CHECK(ghost_delta == 0 && out_diff == 0 && lip_delta >= 80);
    }
    free(px_empty);
    free(px_icon);
    free(px_lip);
  }

  // V9g: Role 4 Tab strictly monotonic (empty vs bar A/B diff across d=0..4.0pt, px_x=96..108)
  {
    double tg[3 * MB_INST];
    fill_p0_rect(tg, 0, 0, VW, VH, 0, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0, 1.0, 0);
    fill_p0_rect(tg + MB_INST, 32.5, 8.25, 95.0, 63.5, 6, 1.0, 1.0, 1.0, 0.0, -5650.0);
    tg[MB_INST + 4] = 31.75; tg[MB_INST + 6] = 1.0; tg[MB_INST + 7] = -64.0;
    tg[MB_INST + 12] = 1.0; tg[MB_INST + 13] = 9.0; tg[MB_INST + 15] = 1.0; tg[MB_INST + 21] = 9.0;
    uint8_t *pxg_empty = render_rgba_pixels_of(tg, 2, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0, 3.0, AW3, AH3);
    fill_p0_rect(tg + MB_INST, 37.5, 8.0, 1.5, 64.0, 0, 90.0 / 255.0, 90.0 / 255.0, 90.0 / 255.0, 1.0, 0);
    fill_p0_rect(tg + 2 * MB_INST, 32.5, 8.25, 95.0, 63.5, 6, 1.0, 1.0, 1.0, 0.0, -565.0);
    tg[2 * MB_INST + 4] = 31.75; tg[2 * MB_INST + 6] = 1.0; tg[2 * MB_INST + 7] = -64.0;
    tg[2 * MB_INST + 12] = 1.0; tg[2 * MB_INST + 13] = 9.0; tg[2 * MB_INST + 15] = 1.0; tg[2 * MB_INST + 21] = 9.0;
    uint8_t *pxg_bar = render_rgba_pixels_of(tg, 3, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0, 3.0, AW3, AH3);
    CHECK(pxg_empty != NULL && pxg_bar != NULL);
    if (pxg_empty && pxg_bar) {
      uint8_t *co = W_PX(pxg_bar, AW3, 117, 120);
      double l_bar = 0.2126 * co[0] + 0.7152 * co[1] + 0.0722 * co[2];
      double ghost_diff = 0.0;
      double l_clean = 255.0;
      for (int px_x = 96; px_x <= 108; px_x++) {
        uint8_t *ce = W_PX(pxg_empty, AW3, px_x, 120);
        uint8_t *cb = W_PX(pxg_bar, AW3, px_x, 120);
        double le = 0.2126 * ce[0] + 0.7152 * ce[1] + 0.0722 * ce[2];
        double lb = 0.2126 * cb[0] + 0.7152 * cb[1] + 0.0722 * cb[2];
        double gd = fabs(lb - le);
        if (gd > ghost_diff) ghost_diff = gd;
        if (px_x >= 99 && lb < l_clean) l_clean = lb;
      }
      printf("win_gpu: v9_tab_no_ghost bar_L=%.1f ghost_diff=%.1f clean_L=%.1f\n", l_bar, ghost_diff, l_clean);
      CHECK(l_bar < 130.0 && ghost_diff <= 2.0 && l_clean > 220.0);
    }
    free(pxg_empty);
    free(pxg_bar);
  }

  // V9-Tab-Dark-Clarity: Dark Mode 50pt bar + 62pt Role 4 droplet (6pt overhang clarity & no dead-black side border)
  {
    double td[3 * MB_INST];
    fill_p0_rect(td, 0, 0, VW, VH, 0, 25.0 / 255.0, 27.0 / 255.0, 30.0 / 255.0, 1.0, 0);
    fill_p0_rect(td + MB_INST, 10, 15, 140, 50, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, 0x67 / 255.0, -567.0);
    td[MB_INST + 4] = 25.0; td[MB_INST + 6] = 1.0; td[MB_INST + 7] = 0.0;
    td[MB_INST + 12] = 0.6; td[MB_INST + 13] = 14.0; td[MB_INST + 15] = 1.0; td[MB_INST + 21] = 20.0;
    fill_p0_rect(td + 2 * MB_INST, 35, 9, 90, 62, 6, 1.0, 1.0, 1.0, 0.0, -568.0);
    td[2 * MB_INST + 4] = 31.0; td[2 * MB_INST + 6] = 1.0; td[2 * MB_INST + 7] = -64.0;
    td[2 * MB_INST + 12] = 1.0; td[2 * MB_INST + 13] = 9.0; td[2 * MB_INST + 15] = 1.0; td[2 * MB_INST + 21] = 9.0;
    uint8_t *pxd = render_rgba_pixels_of(td, 3, 25.0 / 255.0, 27.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
    CHECK(pxd != NULL);
    if (pxd) {
      uint8_t *ct = W_PX(pxd, AW3, 240, 36);
      uint8_t *cb = W_PX(pxd, AW3, 240, 204);
      uint8_t *cl = W_PX(pxd, AW3, 106, 120);
      uint8_t *cr = W_PX(pxd, AW3, 373, 120);
      double top_L = 0.2126 * ct[0] + 0.7152 * ct[1] + 0.0722 * ct[2];
      double bot_L = 0.2126 * cb[0] + 0.7152 * cb[1] + 0.0722 * cb[2];
      double left_L = 0.2126 * cl[0] + 0.7152 * cl[1] + 0.0722 * cl[2];
      double right_L = 0.2126 * cr[0] + 0.7152 * cr[1] + 0.0722 * cr[2];
      printf("win_gpu: v9_tab_dark_clarity top_L=%.1f bot_L=%.1f left_L=%.1f right_L=%.1f\n", top_L, bot_L, left_L, right_L);
      CHECK(top_L < 55.0 && bot_L < 55.0 && left_L >= 42.0 && right_L >= 42.0);
      free(pxd);
    }
  }

  // V9a2: Switch ON @ 2x phase-shifted integrated green mass
  {
    const int AW2 = VW * 2, AH2 = VH * 2;
    for (int ph = 0; ph < 2; ph++) {
      double yoff = ph * 0.25;
      double sw[3 * MB_INST];
      fill_p0_rect(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
      fill_p0_rect(sw + MB_INST, 40, 26 + yoff, 63, 28, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 1.0, 0);
      sw[MB_INST + 4] = 14.0;
      fill_p0_rect(sw + 2 * MB_INST, 52.9, 21.0 + yoff, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, (double)(-57 - ph));
      sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
      sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0; sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0;
      uint8_t *px = render_rgba_pixels_of(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 2.0, AW2, AH2);
      CHECK(px != NULL);
      if (px) {
        int gsum = 0;
        for (int dy = 0; dy < 3; dy++) {
          uint8_t *c = W_PX(px, AW2, 80 * 2, 21 * 2 + dy);
          int d = (int)c[1] - (int)c[0];
          if (d > 0) gsum += d;
        }
        printf("win_gpu: v9_switch_on_2x phase=%d green_mass=%d\n", ph, gsum);
        CHECK(gsum > 40);
        free(px);
      }
    }
  }

  // V10: Regular Glass Light Parabolic AA (@2x, R=24pt)
  {
    const int AW2 = VW * 2, AH2 = VH * 2;
    double rg[2 * MB_INST];
    fill_p0_rect(rg, 0, 0, VW, VH, 0, 242.0 / 255.0, 240.0 / 255.0, 236.0 / 255.0, 1.0, 0);
    fill_p0_rect(rg + MB_INST, 20, 10, 120, 60, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 0.40, -70.0);
    rg[MB_INST + 4] = 24.0; rg[MB_INST + 6] = 1.0; rg[MB_INST + 7] = 0.0;
    rg[MB_INST + 12] = 0.6; rg[MB_INST + 13] = 14.0; rg[MB_INST + 15] = 1.0; rg[MB_INST + 21] = 20.0;
    uint8_t *px = render_rgba_pixels_of(rg, 2, 242.0 / 255.0, 240.0 / 255.0, 236.0 / 255.0, 2.0, AW2, AH2);
    CHECK(px != NULL);
    if (px) {
      double masses[64];
      int n = 0;
      const double bg_L = 0.2126 * 242.0 + 0.7152 * 240.0 + 0.0722 * 236.0;
      for (int py = 20 + 4; py <= 20 + 44; py++) {
        double mass = 0.0;
        for (int xpx = 140 * 2 - 48; xpx <= 140 * 2 + 2; xpx++) {
          uint8_t *c = W_PX(px, AW2, xpx, py);
          double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
          if (L < bg_L) mass += (bg_L - L);
        }
        masses[n++] = mass / 2.0;
      }
      double max_d2 = 0.0;
      for (int i = 1; i < n - 1; i++) {
        double d2 = fabs(masses[i - 1] - 2.0 * masses[i] + masses[i + 1]);
        if (d2 > max_d2) max_d2 = d2;
      }
      double side_lmin = 1e9;
      for (int xpx = 140 * 2 - 8; xpx <= 140 * 2 + 2; xpx++) {
        uint8_t *c = W_PX(px, AW2, xpx, 40 * 2);
        double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
        if (L < side_lmin) side_lmin = L;
      }
      uint8_t *lc_outer_top = W_PX(px, AW2, 80 * 2, 10 * 2 - 1);
      uint8_t *lc_top = W_PX(px, AW2, 80 * 2, 10 * 2);
      uint8_t *lc_mid = W_PX(px, AW2, 80 * 2, 40 * 2);
      double light_outer_top_L = 0.2126 * lc_outer_top[0] + 0.7152 * lc_outer_top[1] + 0.0722 * lc_outer_top[2];
      double light_top_L = 0.2126 * lc_top[0] + 0.7152 * lc_top[1] + 0.0722 * lc_top[2];
      double light_mid_L = 0.2126 * lc_mid[0] + 0.7152 * lc_mid[1] + 0.0722 * lc_mid[2];
      printf("win_gpu: v10_reg_light_2x max_d2=%.2f side_lmin=%.2f outer_top_L=%.1f top_L=%.1f mid_L=%.1f\n",
             max_d2, side_lmin, light_outer_top_L, light_top_L, light_mid_L);
      CHECK(max_d2 <= 14.0);
      CHECK(side_lmin >= 150.0 && side_lmin <= 176.0);
      CHECK(light_outer_top_L <= light_mid_L - 15.0);
      CHECK(light_top_L >= light_mid_L);
      free(px);
    }
    double rgd[2 * MB_INST];
    fill_p0_rect(rgd, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
    fill_p0_rect(rgd + MB_INST, 20, 10, 120, 60, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, 0x67 / 255.0, -71.0);
    rgd[MB_INST + 4] = 24.0; rgd[MB_INST + 6] = 1.0; rgd[MB_INST + 7] = 0.0;
    rgd[MB_INST + 12] = 0.6; rgd[MB_INST + 13] = 14.0; rgd[MB_INST + 15] = 1.0; rgd[MB_INST + 21] = 20.0;
    uint8_t *pxd = render_rgba_pixels_of(rgd, 2, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 2.0, AW2, AH2);
    CHECK(pxd != NULL);
    if (pxd) {
      uint8_t *dc_mid = W_PX(pxd, AW2, 80 * 2, 40 * 2);
      uint8_t *dc_top = W_PX(pxd, AW2, 80 * 2, 10 * 2);
      uint8_t *dc_side_in = W_PX(pxd, AW2, 140 * 2 - 1, 40 * 2);
      uint8_t *dc_side_out = W_PX(pxd, AW2, 140 * 2, 40 * 2);
      double l_mid = 0.2126 * dc_mid[0] + 0.7152 * dc_mid[1] + 0.0722 * dc_mid[2];
      double l_top = 0.2126 * dc_top[0] + 0.7152 * dc_top[1] + 0.0722 * dc_top[2];
      double l_side_in = 0.2126 * dc_side_in[0] + 0.7152 * dc_side_in[1] + 0.0722 * dc_side_in[2];
      double l_side_out = 0.2126 * dc_side_out[0] + 0.7152 * dc_side_out[1] + 0.0722 * dc_side_out[2];
      uint64_t dh = 14695981039346656037ULL;
      for (int py = 10 * 2; py <= 10 * 2 + 8; py++) {
        uint8_t *c = W_PX(pxd, AW2, 80 * 2, py);
        for (int ch = 0; ch < 4; ch++) { dh ^= c[ch]; dh *= 1099511628211ULL; }
      }
      for (int xpx = 140 * 2 - 8; xpx <= 140 * 2 + 1; xpx++) {
        uint8_t *c = W_PX(pxd, AW2, xpx, 40 * 2);
        for (int ch = 0; ch < 4; ch++) { dh ^= c[ch]; dh *= 1099511628211ULL; }
      }
      for (int py = 10 * 2; py <= 10 * 2 + 48; py++) {
        for (int xpx = 140 * 2 - 48; xpx <= 140 * 2 + 2; xpx++) {
          uint8_t *c = W_PX(pxd, AW2, xpx, py);
          for (int ch = 0; ch < 4; ch++) { dh ^= c[ch]; dh *= 1099511628211ULL; }
        }
      }
      printf("win_gpu: v10_reg_dark_2x top=%.1f mid=%.1f side_in=%.1f side_out=%.1f roi_fnv1a=0x%016llx\n", l_top, l_mid, l_side_in, l_side_out, (unsigned long long)dh);
      CHECK(l_top > l_mid + 20.0);
      CHECK(l_side_out <= 14.0 && l_side_out < l_mid - 40.0);
      CHECK(l_side_in >= l_mid - 6.0);
      free(pxd);
    }
    // V10-Dark-On-Bright: Dark Regular glass on #F2F3F0 bright backdrop has no dead-black contour (>= 120/255) and bright top rim.
    double rgdb[2 * MB_INST];
    fill_p0_rect(rgdb, 0, 0, VW, VH, 0, 242.0 / 255.0, 243.0 / 255.0, 240.0 / 255.0, 1.0, 0);
    fill_p0_rect(rgdb + MB_INST, 20, 10, 120, 60, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, 0x67 / 255.0, -72.0);
    rgdb[MB_INST + 4] = 24.0; rgdb[MB_INST + 6] = 1.0; rgdb[MB_INST + 7] = 0.0;
    rgdb[MB_INST + 12] = 0.6; rgdb[MB_INST + 13] = 14.0; rgdb[MB_INST + 15] = 1.0; rgdb[MB_INST + 21] = 20.0;
    uint8_t *pxdb = render_rgba_pixels_of(rgdb, 2, 242.0 / 255.0, 243.0 / 255.0, 240.0 / 255.0, 2.0, AW2, AH2);
    CHECK(pxdb != NULL);
    if (pxdb) {
      uint8_t *db_mid = W_PX(pxdb, AW2, 80 * 2, 40 * 2);
      uint8_t *db_top = W_PX(pxdb, AW2, 80 * 2, 10 * 2);
      uint8_t *db_side_out = W_PX(pxdb, AW2, 140 * 2, 40 * 2);
      int db_out_min = db_side_out[0] < db_side_out[1] ? db_side_out[0] : db_side_out[1];
      if (db_side_out[2] < db_out_min) db_out_min = db_side_out[2];
      double db_l_mid = 0.2126 * db_mid[0] + 0.7152 * db_mid[1] + 0.0722 * db_mid[2];
      double db_l_top = 0.2126 * db_top[0] + 0.7152 * db_top[1] + 0.0722 * db_top[2];
      printf("win_gpu: v10_reg_dark_on_bright_2x out_min=%d top=%.1f mid=%.1f\n", db_out_min, db_l_top, db_l_mid);
      CHECK(db_out_min >= 120);
      CHECK(db_l_top > db_l_mid + 20.0);
      free(pxdb);
    }
    // V12-AntiSmear: Regular Light blur=1.2pt at 3x over 2pt alternating dark/light strokes must preserve contrast
    {
      double sm[7 * MB_INST];
      fill_p0_rect(sm, 0, 0, VW, VH, 0, 244.0 / 255.0, 241.0 / 255.0, 234.0 / 255.0, 1.0, 0);
      for (int si = 0; si < 5; si++) {
        fill_p0_rect(sm + (si + 1) * MB_INST, 20, 30 + si * 4, 120, 2, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
      }
      fill_p0_rect(sm + 6 * MB_INST, 20, 10, 120, 60, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 0x67 / 255.0, -711.0);
      sm[6 * MB_INST + 4] = 24.0; sm[6 * MB_INST + 6] = 1.0; sm[6 * MB_INST + 7] = 1.2;
      sm[6 * MB_INST + 12] = 0.6; sm[6 * MB_INST + 13] = 20.0; sm[6 * MB_INST + 15] = 1.0;
      sm[6 * MB_INST + 21] = 28.0; sm[6 * MB_INST + 22] = 0.06;
      uint8_t *pxs = render_rgba_pixels_of(sm, 7, 244.0 / 255.0, 241.0 / 255.0, 234.0 / 255.0, 3.0, AW3, AH3);
      CHECK(pxs != NULL);
      if (pxs) {
        double sm_min = 1e9, sm_max = -1.0;
        for (int py = 34 * 3; py <= 42 * 3; py++) {
          uint8_t *c = W_PX(pxs, AW3, 80 * 3, py);
          double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
          if (L < sm_min) sm_min = L;
          if (L > sm_max) sm_max = L;
        }
        printf("win_gpu: v12_reg_antismear_3x min_L=%.1f max_L=%.1f delta=%.1f\n", sm_min, sm_max, sm_max - sm_min);
        CHECK(sm_max - sm_min >= 4.0 && sm_min >= 170.0);
        free(pxs);
      }
    }
  }

  // V11-AA & V11-Wall: Switch ON (Dark & Light, 3x & 2x, shadow-free)
  for (int is_light = 0; is_light <= 1; is_light++) {
    double bg = is_light ? 1.0 : 28.0 / 255.0;
    double bg_b = is_light ? 1.0 : 30.0 / 255.0;
    double tr_r = is_light ? 52.0 / 255.0 : 48.0 / 255.0;
    double tr_g = is_light ? 199.0 / 255.0 : 209.0 / 255.0;
    double tr_b = is_light ? 89.0 / 255.0 : 88.0 / 255.0;
    for (int sc_idx = 0; sc_idx < 2; sc_idx++) {
      int sc = (sc_idx == 0) ? 3 : 2;
      int aw = 120 * sc, ah = 65 * sc;
      double sw[3 * MB_INST];
      fill_p0_rect(sw, 0, 0, 120, 65, 0, bg, bg, bg_b, 1.0, 0);
      fill_p0_rect(sw + MB_INST, 18.5, 18.0, 63.0, 28.0, 0, tr_r, tr_g, tr_b, 1.0, 0);
      sw[MB_INST + 4] = 14.0;
      sw[MB_INST + 36] = 14.0; sw[MB_INST + 37] = 14.0; sw[MB_INST + 38] = 14.0; sw[MB_INST + 39] = 14.0;
      fill_p0_rect(sw + 2 * MB_INST, 31.58, 12.8, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, (double)(-72 - is_light * 2 - sc_idx));
      sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
      sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0; sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0;
      uint8_t *px = render_rgba_pixels_of(sw, 3, bg, bg, bg_b, (double)sc, aw, ah);
      CHECK(px != NULL);
      if (!px) continue;
      int y_lo = (int)ceil((32.0 - 0.52 * 19.2) * sc - 0.5);
      int y_hi = (int)floor((32.0 + 0.52 * 19.2) * sc - 0.5);
      int xl0 = (sc == 3) ? 89 : 58, xl1 = (sc == 3) ? 109 : 74;
      int xr0 = (sc == 3) ? 259 : 170, xr1 = (sc == 3) ? 281 : 188;
      double minL[128], minR[128];
      int n = 0;
      for (int py = y_lo; py <= y_hi; py++) {
        double ml = 1e9, mr = 1e9;
        for (int xpx = xl0; xpx <= xl1; xpx++) {
          uint8_t *c = W_PX(px, aw, xpx, py);
          double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
          if (L < ml) ml = L;
        }
        for (int xpx = xr0; xpx <= xr1; xpx++) {
          uint8_t *c = W_PX(px, aw, xpx, py);
          double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
          if (L < mr) mr = L;
        }
        minL[n] = ml; minR[n] = mr; n++;
      }
      double d2L = 0.0, d2R = 0.0;
      for (int i = 1; i < n - 1; i++) {
        double a = fabs(minL[i - 1] - 2.0 * minL[i] + minL[i + 1]);
        double b = fabs(minR[i - 1] - 2.0 * minR[i] + minR[i + 1]);
        if (a > d2L) d2L = a;
        if (b > d2R) d2R = b;
      }
      double lim = (sc == 3) ? (is_light ? 12.0 : 10.0) : (is_light ? 14.0 : 12.0);
      printf("win_gpu: v11_aa(%s %dx [%d..%d]) L=%.2f R=%.2f (lim=%.1f)\n",
             is_light ? "light" : "dark", sc, y_lo, y_hi, d2L, d2R, lim);
      CHECK(d2L <= lim && d2R <= lim);
      if (sc == 3) {
        int cy_px = 32 * 3;
        int rx_min = 271;
        double r_minL = 1e9;
        for (int xpx = 268; xpx <= 272; xpx++) {
          uint8_t *c = W_PX(px, aw, xpx, cy_px);
          double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
          if (L < r_minL) { r_minL = L; rx_min = xpx; }
        }
        uint8_t *rc0 = W_PX(px, aw, rx_min, cy_px);
        int r_gr = (int)rc0[1] - (int)rc0[0];
        double l1, l2, l3, l4;
        {
          uint8_t *c1 = W_PX(px, aw, rx_min - 1, cy_px);
          uint8_t *c2 = W_PX(px, aw, rx_min - 2, cy_px);
          uint8_t *c3 = W_PX(px, aw, rx_min - 3, cy_px);
          uint8_t *c4 = W_PX(px, aw, rx_min - 4, cy_px);
          l1 = 0.2126 * c1[0] + 0.7152 * c1[1] + 0.0722 * c1[2];
          l2 = 0.2126 * c2[0] + 0.7152 * c2[1] + 0.0722 * c2[2];
          l3 = 0.2126 * c3[0] + 0.7152 * c3[1] + 0.0722 * c3[2];
          l4 = 0.2126 * c4[0] + 0.7152 * c4[1] + 0.0722 * c4[2];
        }
        int r_mono = (l1 >= r_minL && l2 >= l1 && l3 >= l2 && l4 >= l3);
        int best_gr = -999, best_g = 0;
        for (int xpx = 94; xpx <= 98; xpx++) {
          uint8_t *c = W_PX(px, aw, xpx, cy_px);
          int gr = (int)c[1] - (int)c[0];
          if (gr > best_gr && c[1] >= 125 && c[1] <= 165) { best_gr = gr; best_g = c[1]; }
        }
        printf("win_gpu: v11_wall(%s 3x) r_minL=%.1f@x=%d r_gr=%d wall=(%.1f,%.1f,%.1f,%.1f) r_mono=%d l_emerald=(G=%d,G-R=%d)\n",
               is_light ? "light" : "dark", r_minL, rx_min, r_gr, l1, l2, l3, l4, r_mono, best_g, best_gr);
        if (!is_light) {
          CHECK(r_minL <= 14.0 && r_gr <= 12 && r_mono);
        } else {
          CHECK(r_minL >= 170.0 && r_minL <= 205.0 && r_mono && l4 >= 230.0);
        }
        CHECK(best_gr >= 90 && best_g >= 125 && best_g <= 165);
        {
          double prev_moat = -1.0;
          printf("win_gpu: v9_left_horn_3x(%s)", is_light ? "light" : "dark");
          for (int dx = 6; dx <= 20; dx += 2) {
            int pc = (int)lround((31.58 + dx) * 3.0);
            double dyc = sqrt(fmax(19.2 * 19.2 - fmax(19.2 - dx, 0.0) * fmax(19.2 - dx, 0.0), 0.0));
            int y0 = (int)lround((32.0 - dyc + 1.0) * 3.0);
            int y1 = (int)lround(32.0 * 3.0);
            int best = 0, cur = 0;
            for (int py = y0; py < y1; py++) {
              uint8_t *c = W_PX(px, aw, pc, py);
              if ((int)c[1] - (int)c[0] < 26) { cur++; if (cur > best) best = cur; } else cur = 0;
            }
            double mpt = best / 3.0;
            printf(" dx=%d:%.2f", dx, mpt);
            if (dx == 6 || dx == 8) CHECK(mpt == 0.0);
            if (dx == 10) CHECK(mpt >= 1.5 && mpt <= 4.5);
            if (dx >= 12 && prev_moat >= 0.0) CHECK(mpt >= prev_moat - 0.35 && mpt - prev_moat <= 3.5);
            if (dx == 20) CHECK(mpt >= 7.0);
            prev_moat = mpt;
          }
          printf("\n");
        }
      }
      free(px);
    }
  }

  // V11-Top: Registered 3x & 2x top-wall at 5.00pt & 5.20pt (Dark & Light)
  {
    double offs[2] = { 5.00, 5.20 };
    for (int is_light = 0; is_light <= 1; is_light++) {
      double bg = is_light ? 1.0 : 28.0 / 255.0;
      double bg_b = is_light ? 1.0 : 30.0 / 255.0;
      double tr_r = is_light ? 52.0 / 255.0 : 48.0 / 255.0;
      double tr_g = is_light ? 199.0 / 255.0 : 209.0 / 255.0;
      double tr_b = is_light ? 89.0 / 255.0 : 88.0 / 255.0;
      for (int oi = 0; oi < 2; oi++) {
        double off = offs[oi], th = 38.4 - 2.0 * off;
        for (int sc_idx = 0; sc_idx < 2; sc_idx++) {
          int sc = (sc_idx == 0) ? 3 : 2;
          int aw = VW * sc, ah = VH * sc;
          double sw[3 * MB_INST];
          fill_p0_rect(sw, 0, 0, VW, VH, 0, bg, bg, bg_b, 1.0, 0);
          fill_p0_rect(sw + MB_INST, 40.0, 21.0 + off, 63.0, th, 0, tr_r, tr_g, tr_b, 1.0, 0);
          sw[MB_INST + 4] = th * 0.5;
          sw[MB_INST + 36] = th * 0.5; sw[MB_INST + 37] = th * 0.5; sw[MB_INST + 38] = th * 0.5; sw[MB_INST + 39] = th * 0.5;
          fill_p0_rect(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, (double)(-80 - is_light * 4 - oi * 2 - sc_idx));
          sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
          sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0; sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0;
          uint8_t *px = render_rgba_pixels_of(sw, 3, bg, bg, bg_b, (double)sc, aw, ah);
          CHECK(px != NULL);
          if (!px) continue;
          uint8_t *r0 = W_PX(px, aw, 80 * sc, 21 * sc + 0);
          uint8_t *r1 = W_PX(px, aw, 80 * sc, 21 * sc + 1);
          uint8_t *r2 = W_PX(px, aw, 80 * sc, 21 * sc + 2);
          int gr0 = (int)r0[1] - (int)r0[0], gr1 = (int)r1[1] - (int)r1[0], gr2 = (int)r2[1] - (int)r2[0];
          double l0 = 0.2126 * r0[0] + 0.7152 * r0[1] + 0.0722 * r0[2];
          double l2 = 0.2126 * r2[0] + 0.7152 * r2[1] + 0.0722 * r2[2];
          printf("win_gpu: v11_top(%s %dx @%.2fpt) r0=(G-R=%d,L=%.0f) r1=(G-R=%d) r2=(G-R=%d,L=%.0f)\n",
                 is_light ? "light" : "dark", sc, off, gr0, l0, gr1, gr2, l2);
          if (sc == 3) {
            if (!is_light) {
              CHECK(gr0 < 15 && l0 <= 35.0 && gr1 >= 100 && gr2 < 15 && l2 >= 75.0);
            } else {
              CHECK(gr0 < 15 && l0 >= 180.0 && l0 <= 215.0 && gr1 >= 95 && gr2 < 15 && l2 >= 245.0);
            }
          } else {
            CHECK(gr1 >= 70 && gr2 < 15);
          }
          free(px);
        }
      }
    }
  }
  // V9h: Switch ON held glassFrost C0 continuity (0 -> eps, 0.108->0.110 veil, 0.127->0.129 blur, 0.60 frosted)
  {
    static const double frosts[8] = { 0.0, 0.0001, 0.00011, 0.108, 0.110, 0.127, 0.129, 0.60 };
    int aw = VW * 3, ah = VH * 3;
    uint8_t *px0 = NULL, *px_prev = NULL;
    int max_d_eps = 0, max_d_veil = 0, max_d_blur = 0;
    int c0_r = 0, c0_g = 0, c60_r = 0, c60_g = 0;
    for (int fi = 0; fi < 8; fi++) {
      double fr = frosts[fi];
      double alpha = 0.0, slot7 = -32.0, refr = 9.0;
      if (fr > 0.0001) {
        double a_frac = 0.94 * fr;
        alpha = round(a_frac * 255.0) / 255.0;
        double bl = (a_frac <= 0.12) ? 0.0 : 14.0 * ((a_frac - 0.12) / 0.88) * 0.5;
        slot7 = (bl <= 0.0) ? -32.0 : bl;
        refr = 9.0 * (1.0 - 0.55 * fr);
      }
      double sw[3 * MB_INST];
      fill_p0_rect(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
      fill_p0_rect(sw + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 1.0, 0);
      sw[MB_INST + 4] = 14.0;
      sw[MB_INST + 36] = 14.0; sw[MB_INST + 37] = 14.0; sw[MB_INST + 38] = 14.0; sw[MB_INST + 39] = 14.0;
      fill_p0_rect(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, alpha, (double)(-90 - fi));
      sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = slot7;
      sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0; sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = refr;
      uint8_t *px = render_rgba_pixels_of(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, aw, ah);
      CHECK(px != NULL);
      if (!px) continue;
      if (fi == 0) {
        px0 = px;
        uint8_t *c = W_PX(px, aw, 82 * 3, 40 * 3);
        c0_r = c[0]; c0_g = c[1];
      } else {
        if (fi == 2 && px0) {
          for (int py = 21 * 3; py <= 59 * 3; py++) {
            for (int xpx = 53 * 3; xpx <= 112 * 3; xpx++) {
              uint8_t *a = W_PX(px0, aw, xpx, py);
              uint8_t *b = W_PX(px, aw, xpx, py);
              for (int ch = 0; ch < 3; ch++) {
                int d = abs((int)a[ch] - (int)b[ch]);
                if (d > max_d_eps) max_d_eps = d;
              }
            }
          }
        } else if (fi == 3 || fi == 5) {
          free(px_prev);
          px_prev = px;
          px = NULL;
        } else if ((fi == 4 || fi == 6) && px_prev) {
          int md = 0;
          for (int py = 21 * 3; py <= 59 * 3; py++) {
            for (int xpx = 53 * 3; xpx <= 112 * 3; xpx++) {
              uint8_t *a = W_PX(px_prev, aw, xpx, py);
              uint8_t *b = W_PX(px, aw, xpx, py);
              for (int ch = 0; ch < 3; ch++) {
                int d = abs((int)a[ch] - (int)b[ch]);
                if (d > md) md = d;
              }
            }
          }
          if (fi == 4) max_d_veil = md; else max_d_blur = md;
        } else if (fi == 7) {
          uint8_t *c = W_PX(px, aw, 82 * 3, 40 * 3);
          c60_r = c[0]; c60_g = c[1];
        }
        free(px);
      }
    }
    free(px0);
    free(px_prev);
    printf("win_gpu: v9_switch_frost_continuity max_d_eps=%d max_d_veil=%d max_d_blur=%d ctr0=(%d,%d) ctr60=(%d,%d)\n",
           max_d_eps, max_d_veil, max_d_blur, c0_r, c0_g, c60_r, c60_g);
    CHECK(max_d_eps <= 2);
    CHECK(max_d_veil <= 10);
    CHECK(max_d_blur <= 10);
    CHECK(c60_r > c0_r + 25 && (c60_g - c60_r) < (c0_g - c0_r) - 20);
  }
  // V11-Unified-Panel-Glass: Light/Dark 0x80 overlay chroma, rim, white-backdrop WCAG >= 4.5:1, and 0xFF solid zero leak
  {
    int aw = VW * 2, ah = VH * 2;
    double pb[2 * MB_INST];
    fill_p0_rect(pb, 0, 0, VW, VH, 0, 211.0 / 255.0, 232.0 / 255.0, 253.0 / 255.0, 1.0, 0);
    fill_p0_rect(pb + MB_INST, 20.0, 10.0, 120.0, 60.0, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 0x80 / 255.0, -98);
    pb[MB_INST + 4] = 22.0; pb[MB_INST + 6] = 1.0; pb[MB_INST + 7] = 14.0;
    pb[MB_INST + 12] = 0.6; pb[MB_INST + 13] = 20.0; pb[MB_INST + 14] = 0.0;
    pb[MB_INST + 15] = 1.0; pb[MB_INST + 21] = 16.0; pb[MB_INST + 22] = 0.0;
    uint8_t *px = render_rgba_pixels_of(pb, 2, 211.0 / 255.0, 232.0 / 255.0, 253.0 / 255.0, 2.0, aw, ah);
    CHECK(px != NULL);
    if (px) {
      uint8_t *rim = W_PX(px, aw, 80 * 2, 20);
      uint8_t *mid = W_PX(px, aw, 80 * 2, 68);
      int mid_br = (int)mid[2] - (int)mid[0];
      double rim_L = 0.2126 * rim[0] + 0.7152 * rim[1] + 0.0722 * rim[2];
      double mid_L = 0.2126 * mid[0] + 0.7152 * mid[1] + 0.0722 * mid[2];
      free(px);
      pb[MB_INST + 11] = 1.0;
      pb[MB_INST + 20] = -99;
      px = render_rgba_pixels_of(pb, 2, 211.0 / 255.0, 232.0 / 255.0, 253.0 / 255.0, 2.0, aw, ah);
      CHECK(px != NULL);
      if (px) {
        uint8_t *sr = W_PX(px, aw, 80 * 2, 20);
        uint8_t *sm = W_PX(px, aw, 80 * 2, 68);
        double sr_L = 0.2126 * sr[0] + 0.7152 * sr[1] + 0.0722 * sr[2];
        double sm_L = 0.2126 * sm[0] + 0.7152 * sm[1] + 0.0722 * sm[2];
        free(px);

        // Light density monotonicity: 0x80 and 0xB3 (frost) over 0.72 grey vs 0.60 grey
        fill_p0_rect(pb, 0, 0, VW, VH, 0, 0.60, 0.60, 0.60, 1.0, 0);
        pb[MB_INST + 11] = 0x80 / 255.0; pb[MB_INST + 20] = -100; pb[MB_INST + 22] = 0.0;
        px = render_rgba_pixels_of(pb, 2, 0.60, 0.60, 0.60, 2.0, aw, ah);
        CHECK(px != NULL);
        double l60 = 0.0, l72 = 0.0, l60_cd = 0.0, l72_cd = 0.0;
        if (px) { uint8_t *m = W_PX(px, aw, 80 * 2, 68); l60 = 0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]; free(px); }
        fill_p0_rect(pb, 0, 0, VW, VH, 0, 0.72, 0.72, 0.72, 1.0, 0);
        pb[MB_INST + 20] = -101;
        px = render_rgba_pixels_of(pb, 2, 0.72, 0.72, 0.72, 2.0, aw, ah);
        CHECK(px != NULL);
        if (px) { uint8_t *m = W_PX(px, aw, 80 * 2, 68); l72 = 0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]; free(px); }
        fill_p0_rect(pb, 0, 0, VW, VH, 0, 0.60, 0.60, 0.60, 1.0, 0);
        pb[MB_INST + 11] = 0xB3 / 255.0; pb[MB_INST + 20] = -105; pb[MB_INST + 22] = 0.0;
        px = render_rgba_pixels_of(pb, 2, 0.60, 0.60, 0.60, 2.0, aw, ah);
        CHECK(px != NULL);
        if (px) { uint8_t *m = W_PX(px, aw, 80 * 2, 68); l60_cd = 0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]; free(px); }
        fill_p0_rect(pb, 0, 0, VW, VH, 0, 0.72, 0.72, 0.72, 1.0, 0);
        pb[MB_INST + 20] = -106;
        px = render_rgba_pixels_of(pb, 2, 0.72, 0.72, 0.72, 2.0, aw, ah);
        CHECK(px != NULL);
        if (px) { uint8_t *m = W_PX(px, aw, 80 * 2, 68); l72_cd = 0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]; free(px); }

        // Dark 0x80 vibrant chroma over (60,120,210), Dark 0xCC calmer chroma, and Dark 0x80 over pure white WCAG >= 4.5:1
        fill_p0_rect(pb, 0, 0, VW, VH, 0, 60.0 / 255.0, 120.0 / 255.0, 210.0 / 255.0, 1.0, 0);
        pb[MB_INST + 8] = 32.0 / 255.0; pb[MB_INST + 9] = 32.0 / 255.0; pb[MB_INST + 10] = 32.0 / 255.0;
        pb[MB_INST + 11] = 0x80 / 255.0; pb[MB_INST + 20] = -102; pb[MB_INST + 22] = 0.0;
        px = render_rgba_pixels_of(pb, 2, 60.0 / 255.0, 120.0 / 255.0, 210.0 / 255.0, 2.0, aw, ah);
        CHECK(px != NULL);
        int d80_br = 0, cc_br = 0;
        double dark_white_L = 999.0;
        if (px) { uint8_t *m = W_PX(px, aw, 80 * 2, 68); d80_br = (int)m[2] - (int)m[0]; free(px); }
        pb[MB_INST + 11] = 0xCC / 255.0; pb[MB_INST + 20] = -104; pb[MB_INST + 22] = 0.0;
        px = render_rgba_pixels_of(pb, 2, 60.0 / 255.0, 120.0 / 255.0, 210.0 / 255.0, 2.0, aw, ah);
        CHECK(px != NULL);
        if (px) { uint8_t *m = W_PX(px, aw, 80 * 2, 68); cc_br = (int)m[2] - (int)m[0]; free(px); }
        fill_p0_rect(pb, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 1.0, 0);
        pb[MB_INST + 11] = 0x80 / 255.0; pb[MB_INST + 20] = -107; pb[MB_INST + 22] = 0.0;
        px = render_rgba_pixels_of(pb, 2, 1.0, 1.0, 1.0, 2.0, aw, ah);
        CHECK(px != NULL);
        if (px) { uint8_t *dw = W_PX(px, aw, 80 * 2, 68); dark_white_L = 0.2126 * dw[0] + 0.7152 * dw[1] + 0.0722 * dw[2]; free(px); }

        // Regular controls (chroma=0.06 vs 0.0) bit-exact zero-diff gate under Light 0x85/0xAB & Dark 0xAB
        int ctrl_max_diff = 0;
        int ctrl_hash_eq = 1;
        struct { int dark; double alpha; double br, bg, bb; } ctrl_cases[3] = {
          { 0, 0x85 / 255.0, 211.0 / 255.0, 232.0 / 255.0, 253.0 / 255.0 },
          { 0, 0xAB / 255.0, 211.0 / 255.0, 232.0 / 255.0, 253.0 / 255.0 },
          { 1, 0xAB / 255.0,  60.0 / 255.0, 120.0 / 255.0, 210.0 / 255.0 },
        };
        pb[MB_INST + 7] = 2.0; pb[MB_INST + 12] = 0.6; pb[MB_INST + 13] = 14.0; pb[MB_INST + 21] = 20.0;
        for (int ci = 0; ci < 3; ci++) {
          fill_p0_rect(pb, 0, 0, VW, VH, 0, ctrl_cases[ci].br, ctrl_cases[ci].bg, ctrl_cases[ci].bb, 1.0, 0);
          pb[MB_INST + 8] = ctrl_cases[ci].dark ? 32.0 / 255.0 : 253.0 / 255.0;
          pb[MB_INST + 9] = ctrl_cases[ci].dark ? 32.0 / 255.0 : 252.0 / 255.0;
          pb[MB_INST + 10] = ctrl_cases[ci].dark ? 32.0 / 255.0 : 253.0 / 255.0;
          pb[MB_INST + 11] = ctrl_cases[ci].alpha;
          pb[MB_INST + 20] = -110 - ci * 2; pb[MB_INST + 22] = 0.06;
          uint8_t *p06 = render_rgba_pixels_of(pb, 2, ctrl_cases[ci].br, ctrl_cases[ci].bg, ctrl_cases[ci].bb, 2.0, aw, ah);
          pb[MB_INST + 20] = -111 - ci * 2; pb[MB_INST + 22] = 0.0;
          uint8_t *p00 = render_rgba_pixels_of(pb, 2, ctrl_cases[ci].br, ctrl_cases[ci].bg, ctrl_cases[ci].bb, 2.0, aw, ah);
          CHECK(p06 != NULL && p00 != NULL);
          if (p06 && p00) {
            uint64_t h06 = 14695981039346656037ULL, h00 = 14695981039346656037ULL;
            for (int ry = 20; ry < 140; ry++) {
              for (int rx = 40; rx < 280; rx++) {
                uint8_t *q06 = W_PX(p06, aw, rx, ry);
                uint8_t *q00 = W_PX(p00, aw, rx, ry);
                for (int c = 0; c < 3; c++) {
                  int d = abs((int)q06[c] - (int)q00[c]);
                  if (d > ctrl_max_diff) ctrl_max_diff = d;
                  h06 = (h06 ^ q06[c]) * 1099511628211ULL;
                  h00 = (h00 ^ q00[c]) * 1099511628211ULL;
                }
              }
            }
            if (h06 != h00) ctrl_hash_eq = 0;
          }
          free(p06); free(p00);
        }

        printf("win_gpu: v11_unified_panel_glass mid_br=%d rim_L=%.1f mid_L=%.1f solid_dL=%.2f l60=%.1f l72=%.1f b3=%.1f->%.1f d80_br=%d cc_br=%d dark_wt_L=%.1f ctrl_diff=%d ctrl_eq=%d\n",
               mid_br, rim_L, mid_L, fabs(sr_L - sm_L), l60, l72, l60_cd, l72_cd, d80_br, cc_br, dark_white_L, ctrl_max_diff, ctrl_hash_eq);
        CHECK(mid_br >= 24);
        CHECK(rim_L >= mid_L + 4.0);
        CHECK(fabs(sr_L - sm_L) <= 1.0);
        CHECK(l72 >= l60 + 2.0);
        CHECK(l72_cd >= l60_cd + 1.0);
        CHECK(d80_br >= 90 && cc_br < d80_br - 25);
        CHECK(dark_white_L <= 102.0);
        CHECK(ctrl_max_diff == 0 && ctrl_hash_eq == 1);
      }
    }
  }
  // V13-Menu-Morph-DualW + V13b: sweep liquid_menu_morph_glass alpha codes & height-adaptive dual_w / zero-frost k=1
  {
    vscale = 2.0;
    float mf[MB_INST];
    float max_step_l = 0.0f, max_step_d = 0.0f, max_step_t = 0.0f;
    float prev_w = -1.0f, w_start = 0.0f, w_end = 0.0f;
    for (int ai = 103; ai <= 147; ai++) {
      memset(mf, 0, sizeof mf);
      mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 120.0f; mf[3] = 60.0f; mf[4] = 24.0f;
      mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f + 2.8f * (float)(ai - 103) / 44.0f;
      mf[8] = 253.0f / 255.0f; mf[9] = 252.0f / 255.0f; mf[10] = 253.0f / 255.0f; mf[11] = (float)ai / 255.0f;
      mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -120.0f; mf[21] = 20.0f;
      Grab g;
      CHECK(grab_of(&g, mf, 0, 1, 1, VW * 2, VH * 2) == 1);
      if (ai == 103) w_start = g.dual_w;
      if (ai == 147) w_end = g.dual_w;
      if (prev_w >= 0.0f) {
        float d = fabsf(g.dual_w - prev_w);
        if (d > max_step_l) max_step_l = d;
      }
      prev_w = g.dual_w;
    }
    prev_w = -1.0f;
    for (int ai = 103; ai <= 136; ai++) {
      memset(mf, 0, sizeof mf);
      mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 120.0f; mf[3] = 60.0f; mf[4] = 24.0f;
      mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f + 2.8f * (float)(ai - 103) / 33.0f;
      mf[8] = 32.0f / 255.0f; mf[9] = 32.0f / 255.0f; mf[10] = 32.0f / 255.0f; mf[11] = (float)ai / 255.0f;
      mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -121.0f; mf[21] = 20.0f;
      Grab g;
      CHECK(grab_of(&g, mf, 0, 1, 1, VW * 2, VH * 2) == 1);
      if (prev_w >= 0.0f) {
        float d = fabsf(g.dual_w - prev_w);
        if (d > max_step_d) max_step_d = d;
      }
      prev_w = g.dual_w;
    }
    prev_w = -1.0f;
    for (int ai = 180; ai <= 210; ai++) {
      memset(mf, 0, sizeof mf);
      mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 120.0f; mf[3] = 60.0f; mf[4] = 24.0f;
      mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f;
      mf[8] = 0.0f; mf[9] = 136.0f / 255.0f; mf[10] = 1.0f; mf[11] = (float)ai / 255.0f;
      mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -122.0f; mf[21] = 20.0f;
      Grab g;
      CHECK(grab_of(&g, mf, 0, 1, 1, VW * 2, VH * 2) == 1);
      if (prev_w >= 0.0f) {
        float d = fabsf(g.dual_w - prev_w);
        if (d > max_step_t) max_step_t = d;
      }
      prev_w = g.dual_w;
    }
    printf("win_gpu: v13_menu_morph_dual_w start=%.3f end=%.3f max_step=(L=%.4f,D=%.4f,T=%.4f)\n",
           w_start, w_end, max_step_l, max_step_d, max_step_t);
    CHECK(w_start >= 0.80f && w_start <= 0.88f && w_end == 0.0f);
    CHECK(max_step_l <= 0.06f && max_step_d <= 0.06f && max_step_t <= 0.07f);
    Grab g44, g62, gclr;
    memset(mf, 0, sizeof mf);
    mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 132.0f; mf[3] = 44.0f; mf[4] = 22.0f;
    mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f;
    mf[8] = 32.0f / 255.0f; mf[9] = 32.0f / 255.0f; mf[10] = 32.0f / 255.0f; mf[11] = 0x67 / 255.0f;
    mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -123.0f; mf[21] = 20.0f;
    CHECK(grab_of(&g44, mf, 0, 1, 1, VW * 2, VH * 2) == 1);
    CHECK(g44.dual_scale == 1 && fabsf(g44.dual_w - 0.68f) < 0.01f && g44.k == 1 && g44.sg == 0.0f);
    mf[2] = 292.0f; mf[3] = 62.0f; mf[4] = 31.0f;
    CHECK(grab_of(&g62, mf, 0, 1, 1, VW * 2, VH * 2) == 1);
    CHECK(g62.dual_scale == 1 && fabsf(g62.dual_w - 0.86f) < 0.01f && g62.k == 1 && g62.sg == 0.0f);
    mf[2] = 100.0f; mf[3] = 44.0f; mf[4] = 22.0f; mf[7] = 0.0f;
    mf[8] = 1.0f; mf[9] = 1.0f; mf[10] = 1.0f; mf[11] = 0x1A / 255.0f;
    CHECK(grab_of(&gclr, mf, 0, 1, 1, VW * 2, VH * 2) == 1);
    CHECK(gclr.dual_scale == 0 && gclr.k == 1 && gclr.sg > 0.3f);
    printf("win_gpu: v13_dual_k1 w44=%.3f w62=%.3f clr_k=%d clr_sg=%.2f\n",
           g44.dual_w, g62.dual_w, gclr.k, gclr.sg);
    // V13c: effective-sigma continuity (no 1-frame sharpness pop) across menu morph (legacy + v9 3-anchor) & size sweep (14..20pt) at 2x & 3x.
    double max_morph_dsig = 0.0, min_morph_dsig = 0.0, max_sz_dsig = 0.0;
    double max_v9_dsig = 0.0, min_v9_dsig = 0.0;
    for (int sc_i = 2; sc_i <= 3; sc_i++) {
      vscale = (double)sc_i;
      double prev_se = -1.0;
      for (int si = 0; si <= 240; si++) {
        float t = (float)si / 240.0f;
        memset(mf, 0, sizeof mf);
        mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 120.0f; mf[3] = 60.0f; mf[4] = 24.0f;
        mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f + 2.8f * t;
        mf[8] = 253.0f / 255.0f; mf[9] = 252.0f / 255.0f; mf[10] = 253.0f / 255.0f;
        mf[11] = (103.0f + 44.0f * t) / 255.0f;
        mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -124.0f; mf[21] = 20.0f;
        Grab gm;
        CHECK(grab_of(&gm, mf, 0, 1, 1, VW * sc_i, VH * sc_i) == 1);
        double pre = gm.k > 0 ? 0.75 * (1.0 - pow(0.25, (double)gm.k)) / 3.0 + 1.0 / 6.0 : 0.0;
        double sgu = (gm.dual_scale && gm.k > 0) ? (gm.sg > 0.55f ? (double)gm.sg : 0.526) : (gm.sg > 0.3f ? (double)gm.sg : 0.0);
        double se = (double)(1 << gm.k) * sqrt(sgu * sgu + pre);
        if (prev_se >= 0.0) {
          double d = se - prev_se;
          if (fabs(d) > max_morph_dsig) max_morph_dsig = fabs(d);
          if (d < min_morph_dsig) min_morph_dsig = d;
        }
        prev_se = se;
      }
      prev_se = -1.0;
      for (int si = 0; si <= 240; si++) {
        float t = (float)si / 240.0f;
        float u = t <= 0.5f ? t * 2.0f : (t - 0.5f) * 2.0f;
        float mb = t <= 0.5f ? (1.2f + 4.8f * u) : (6.0f + 8.0f * u);
        float ma = t <= 0.5f ? (103.0f + 13.0f * u) / 255.0f : (116.0f + 12.0f * u) / 255.0f;
        memset(mf, 0, sizeof mf);
        mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 44.0f + 207.0f * t; mf[3] = 44.0f + 214.0f * t; mf[4] = 22.0f + 10.0f * t;
        mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = mb;
        mf[8] = 253.0f / 255.0f; mf[9] = 252.0f / 255.0f; mf[10] = 253.0f / 255.0f;
        mf[11] = ma;
        mf[12] = 0.6f; mf[13] = 14.0f + 6.0f * t; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -126.0f; mf[21] = 20.0f - 4.0f * t;
        Grab gm;
        CHECK(grab_of(&gm, mf, 0, 1, 1, VW * sc_i, VH * sc_i) == 1);
        double pre = gm.k > 0 ? 0.75 * (1.0 - pow(0.25, (double)gm.k)) / 3.0 + 1.0 / 6.0 : 0.0;
        double sgu = (gm.dual_scale && gm.k > 0) ? (gm.sg > 0.55f ? (double)gm.sg : 0.526) : (gm.sg > 0.3f ? (double)gm.sg : 0.0);
        double se = (double)(1 << gm.k) * sqrt(sgu * sgu + pre);
        if (prev_se >= 0.0) {
          double d = se - prev_se;
          if (fabs(d) > max_v9_dsig) max_v9_dsig = fabs(d);
          if (d < min_v9_dsig) min_v9_dsig = d;
        }
        prev_se = se;
      }
      prev_se = -1.0;
      for (int si = 0; si <= 60; si++) {
        float dim = 14.0f + 6.0f * (float)si / 60.0f;
        memset(mf, 0, sizeof mf);
        mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 120.0f; mf[3] = dim; mf[4] = dim * 0.5f;
        mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f;
        mf[8] = 253.0f / 255.0f; mf[9] = 252.0f / 255.0f; mf[10] = 253.0f / 255.0f; mf[11] = 103.0f / 255.0f;
        mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -125.0f; mf[21] = 20.0f;
        Grab gs;
        CHECK(grab_of(&gs, mf, 0, 1, 1, VW * sc_i, VH * sc_i) == 1);
        double pre = gs.k > 0 ? 0.75 * (1.0 - pow(0.25, (double)gs.k)) / 3.0 + 1.0 / 6.0 : 0.0;
        double sgu = (gs.dual_scale && gs.k > 0) ? (gs.sg > 0.55f ? (double)gs.sg : 0.526) : (gs.sg > 0.3f ? (double)gs.sg : 0.0);
        double se = (double)(1 << gs.k) * sqrt(sgu * sgu + pre);
        if (prev_se >= 0.0) {
          double d = fabs(se - prev_se);
          if (d > max_sz_dsig) max_sz_dsig = d;
        }
        prev_se = se;
      }
    }
    vscale = 2.0;
    printf("win_gpu: v13c_sigma_cont max_morph_dsig=%.3f min_morph_dsig=%.3f v9_3anchor=(%.3f,%.3f) max_sz_dsig=%.3f\n",
           max_morph_dsig, min_morph_dsig, max_v9_dsig, min_v9_dsig, max_sz_dsig);
    CHECK(min_morph_dsig >= -1e-4);
    CHECK(max_morph_dsig <= 0.30);
    CHECK(min_v9_dsig >= -1e-4);
    CHECK(max_v9_dsig <= 0.45);
    CHECK(max_sz_dsig <= 0.30);
  }
  // V14-Opus-Gates: (1) Tinted capsule dark outer contour <= 14; (2) Light Regular rim on black/mid-grey/cream;
  // (3) Clear pill on pure white has zero inner grey band (min_L >= 254).
  {
    int aw = VW * 3, ah = VH * 3;
    // (1) Tinted blue capsule on dark bg: outermost side pixel L <= 14
    double tb[2 * MB_INST];
    fill_p0_rect(tb, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
    fill_p0_rect(tb + MB_INST, 20.0, 18.0, 78.0, 44.0, 6, 0.0, 122.0 / 255.0, 1.0, 0x99 / 255.0, -130);
    tb[MB_INST + 4] = 22.0; tb[MB_INST + 6] = 1.0; tb[MB_INST + 7] = 1.2;
    tb[MB_INST + 12] = 0.6; tb[MB_INST + 13] = 14.0;
    tb[MB_INST + 15] = 1.0; tb[MB_INST + 21] = 20.0; tb[MB_INST + 22] = 0.06;
    uint8_t *pxt = render_rgba_pixels_of(tb, 2, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, aw, ah);
    CHECK(pxt != NULL);
    double tint_side_L = 999.0;
    if (pxt) {
      uint8_t *ts = W_PX(pxt, aw, 98 * 3, 40 * 3);
      tint_side_L = 0.2126 * ts[0] + 0.7152 * ts[1] + 0.0722 * ts[2];
      free(pxt);
    }
    // (2) Light Regular non-adaptive pill on pure black, mid-grey (0.5), and cream:
    double bg_vals[3][3] = { {0.0, 0.0, 0.0}, {0.5, 0.5, 0.5}, {244.0 / 255.0, 241.0 / 255.0, 234.0 / 255.0} };
    double top_d[3] = {0}, top2_d[3] = {0}, top_abs[3] = {0};
    for (int bi = 0; bi < 3; bi++) {
      double lr[2 * MB_INST];
      fill_p0_rect(lr, 0, 0, VW, VH, 0, bg_vals[bi][0], bg_vals[bi][1], bg_vals[bi][2], 1.0, 0);
      fill_p0_rect(lr + MB_INST, 14.0, 18.0, 132.0, 44.0, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 0x67 / 255.0, -131 - bi);
      lr[MB_INST + 4] = 22.0; lr[MB_INST + 6] = 1.0; lr[MB_INST + 7] = 1.2;
      lr[MB_INST + 12] = 0.6; lr[MB_INST + 13] = 14.0;
      lr[MB_INST + 15] = 1.0; lr[MB_INST + 21] = 20.0; lr[MB_INST + 22] = 0.06;
      uint8_t *pxl = render_rgba_pixels_of(lr, 2, bg_vals[bi][0], bg_vals[bi][1], bg_vals[bi][2], 3.0, aw, ah);
      CHECK(pxl != NULL);
      if (pxl) {
        uint8_t *cm = W_PX(pxl, aw, 80 * 3, 40 * 3);
        uint8_t *c0 = W_PX(pxl, aw, 80 * 3, 18 * 3);
        uint8_t *c2 = W_PX(pxl, aw, 80 * 3, 18 * 3 + 2);
        double lm = 0.2126 * cm[0] + 0.7152 * cm[1] + 0.0722 * cm[2];
        double l0 = 0.2126 * c0[0] + 0.7152 * c0[1] + 0.0722 * c0[2];
        double l2 = 0.2126 * c2[0] + 0.7152 * c2[1] + 0.0722 * c2[2];
        top_d[bi] = l0 - lm; top2_d[bi] = l2 - lm; top_abs[bi] = l0;
        free(pxl);
      }
    }
    // (3) Clear pill on pure white: no inner bevel shadow grey band (all interior rows >= 254)
    double cw[2 * MB_INST];
    fill_p0_rect(cw, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 1.0, 0);
    fill_p0_rect(cw + MB_INST, 20.0, 18.0, 100.0, 44.0, 6, 1.0, 1.0, 1.0, 0x1A / 255.0, -135);
    cw[MB_INST + 4] = 22.0; cw[MB_INST + 6] = 1.0; cw[MB_INST + 7] = 0.0;
    cw[MB_INST + 12] = 0.6; cw[MB_INST + 13] = 14.0;
    cw[MB_INST + 15] = 1.0; cw[MB_INST + 21] = 16.0;
    uint8_t *pxc = render_rgba_pixels_of(cw, 2, 1.0, 1.0, 1.0, 3.0, aw, ah);
    CHECK(pxc != NULL);
    double clr_min_L = 999.0;
    if (pxc) {
      for (int py = 18 * 3 + 2; py <= 62 * 3 - 2; py++) {
        uint8_t *cp = W_PX(pxc, aw, 70 * 3, py);
        double L = 0.2126 * cp[0] + 0.7152 * cp[1] + 0.0722 * cp[2];
        if (L < clr_min_L) clr_min_L = L;
      }
      free(pxc);
    }
    printf("win_gpu: v14_opus_gates tint_side=%.1f blk_d=(+%.1f,+%.1f) mid_d=(+%.1f,+%.1f) crm=%.1f clr_min=%.1f\n",
           tint_side_L, top_d[0], top2_d[0], top_d[1], top2_d[1], top_abs[2], clr_min_L);
    CHECK(tint_side_L <= 14.0);
    CHECK(top_d[0] <= 50.0 && top2_d[0] <= 28.0);
    CHECK(top_d[1] <= 38.0 && top2_d[1] <= 18.0);
    CHECK(top_abs[2] >= 252.0);
    CHECK(clr_min_L >= 254.0);
    // V14b-Scroll-Shimmer: 1px vertical scroll shift-invariance of 44pt Light Regular pill over crisp dark strokes at 2x & 3x.
    for (int sc_i = 2; sc_i <= 3; sc_i++) {
      int sw_px = VW * sc_i, sh_px = VH * sc_i;
      uint8_t *fpx[2] = {NULL, NULL};
      for (int fi = 0; fi < 2; fi++) {
        double dy = (double)fi / (double)sc_i;
        double sb[7 * MB_INST];
        fill_p0_rect(sb, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 1.0, 0);
        fill_p0_rect(sb + 1 * MB_INST, 0, 24.0 + dy, VW, 1.0, 0, 0.08, 0.08, 0.08, 1.0, 0);
        fill_p0_rect(sb + 2 * MB_INST, 0, 31.0 + dy, VW, 1.5, 0, 0.08, 0.08, 0.08, 1.0, 0);
        fill_p0_rect(sb + 3 * MB_INST, 0, 39.0 + dy, VW, 2.0, 0, 0.08, 0.08, 0.08, 1.0, 0);
        fill_p0_rect(sb + 4 * MB_INST, 0, 47.0 + dy, VW, 1.0, 0, 0.08, 0.08, 0.08, 1.0, 0);
        fill_p0_rect(sb + 5 * MB_INST, 0, 54.0 + dy, VW, 2.0, 0, 0.08, 0.08, 0.08, 1.0, 0);
        fill_p0_rect(sb + 6 * MB_INST, 14.0, 18.0, 132.0, 44.0, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 0x67 / 255.0, -140 - sc_i * 2 - fi);
        sb[6 * MB_INST + 4] = 22.0; sb[6 * MB_INST + 6] = 1.0; sb[6 * MB_INST + 7] = 1.2;
        sb[6 * MB_INST + 12] = 0.6; sb[6 * MB_INST + 13] = 14.0;
        sb[6 * MB_INST + 15] = 1.0; sb[6 * MB_INST + 21] = 20.0; sb[6 * MB_INST + 22] = 0.06;
        fpx[fi] = render_rgba_pixels_of(sb, 7, 1.0, 1.0, 1.0, (double)sc_i, sw_px, sh_px);
        CHECK(fpx[fi] != NULL);
      }
      if (fpx[0] && fpx[1]) {
        double max_d_flat = 0.0, sum2_flat = 0.0;
        int cnt_flat = 0;
        for (int py = 28 * sc_i; py < 52 * sc_i - 1; py++) {
          for (int px = 44 * sc_i; px < 116 * sc_i; px++) {
            uint8_t *p0 = W_PX(fpx[0], sw_px, px, py);
            uint8_t *p1 = W_PX(fpx[1], sw_px, px, py + 1);
            double l0 = 0.2126 * p0[0] + 0.7152 * p0[1] + 0.0722 * p0[2];
            double l1 = 0.2126 * p1[0] + 0.7152 * p1[1] + 0.0722 * p1[2];
            double d = fabs(l1 - l0);
            if (d > max_d_flat) max_d_flat = d;
            sum2_flat += d * d;
            cnt_flat++;
          }
        }
        double rms_flat = sqrt(sum2_flat / (double)(cnt_flat > 0 ? cnt_flat : 1));
        printf("win_gpu: v14b_scroll_shimmer_%dx flat_max=%.2f flat_rms=%.2f\n", sc_i, max_d_flat, rms_flat);
        CHECK(max_d_flat <= 3.0);
      }
      free(fpx[0]); free(fpx[1]);
    }
    // V14c-DualSlot-MidSg: 2x blur=2.1pt tint=0x67 falls in 0.3 < sg <= 0.55 (sg~0.438).
    {
      vscale = 2.0;
      float mf21[MB_INST];
      memset(mf21, 0, sizeof mf21);
      mf21[0] = 14.0f; mf21[1] = 18.0f; mf21[2] = 132.0f; mf21[3] = 44.0f; mf21[4] = 22.0f;
      mf21[5] = 6.0f; mf21[6] = 1.0f; mf21[7] = 2.1f;
      mf21[8] = 253.0f / 255.0f; mf21[9] = 252.0f / 255.0f; mf21[10] = 253.0f / 255.0f; mf21[11] = 0x67 / 255.0f;
      mf21[12] = 0.6f; mf21[13] = 14.0f; mf21[15] = 1.0f; mf21[18] = (float)VW; mf21[19] = (float)VH; mf21[20] = -149.0f; mf21[21] = 20.0f;
      Grab g21;
      CHECK(grab_of(&g21, mf21, 0, 1, 1, VW * 2, VH * 2) == 1);
      CHECK(g21.dual_scale == 1 && g21.k == 1 && g21.sg > 0.30f && g21.sg <= 0.55f);
      CHECK(grab_blurred(&g21) == &lv[4]);
      double s21[3 * MB_INST];
      fill_p0_rect(s21, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 1.0, 0);
      fill_p0_rect(s21 + MB_INST, 74.0, 0, 12.0, VH, 0, 0.05, 0.05, 0.05, 1.0, 0);
      fill_p0_rect(s21 + 2 * MB_INST, 14.0, 18.0, 132.0, 44.0, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 0x67 / 255.0, -149);
      s21[2 * MB_INST + 4] = 22.0; s21[2 * MB_INST + 6] = 1.0; s21[2 * MB_INST + 7] = 2.1;
      s21[2 * MB_INST + 12] = 0.6; s21[2 * MB_INST + 13] = 14.0;
      s21[2 * MB_INST + 15] = 1.0; s21[2 * MB_INST + 21] = 20.0; s21[2 * MB_INST + 22] = 0.06;
      uint8_t *p1 = render_rgba_pixels_of(s21, 3, 1.0, 1.0, 1.0, 2.0, VW * 2, VH * 2);
      CHECK(p1 != NULL);
      if (p1) {
        uint8_t *cb = W_PX(p1, VW * 2, 80 * 2, 40 * 2);
        uint8_t *cw1 = W_PX(p1, VW * 2, 50 * 2, 40 * 2);
        double l_bar = 0.2126 * cb[0] + 0.7152 * cb[1] + 0.0722 * cb[2];
        double l_wh = 0.2126 * cw1[0] + 0.7152 * cw1[1] + 0.0722 * cw1[2];
        printf("win_gpu: v14c_dual_slot_midsg sg=%.3f bar_L=%.1f wh_L=%.1f diff=%.1f\n",
               g21.sg, l_bar, l_wh, l_wh - l_bar);
        CHECK(l_bar >= 185.0 && (l_wh - l_bar) <= 65.0);
        free(p1);
      }
    }
    // V15-Unified-V9-Gates: (1) 2x blur=4pt (k=2) flat 0.5 grey stays ~195 (no sRGB/linear mix corruption);
    // (2) Light 0x67 over 10% white bars on pure black stays <= 150 (no linear over-bloom on dark backdrop);
    // (3) Adaptive 0xFF solid over black vs white is identical (<= 1 LSB);
    // (4) Shared capture Light+Dark vs Dark+Light order-invariant (0 LSB diff);
    // (5) Dark 0x80 grayscale sweep Y=0..1 strictly monotonic & white <= 102;
    // (6) Overlay outside-shadow top-edge vertical profile smooth (sh_jump < 2.5).
    {
      int aw2 = 160 * 2, ah2 = 80 * 2;
      int aw3 = 160 * 3, ah3 = 80 * 3;
      double fg[2 * MB_INST];
      fill_p0_rect(fg, 0, 0, 160, 80, 0, 0.5, 0.5, 0.5, 1.0, 0);
      fill_p0_rect(fg + MB_INST, 14, 9, 132, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, 0x67 / 255.0, -151);
      fg[MB_INST + 4] = 31.0; fg[MB_INST + 6] = 1.0; fg[MB_INST + 7] = 4.0;
      fg[MB_INST + 12] = 0.6; fg[MB_INST + 13] = 14.0;
      fg[MB_INST + 15] = 1.0; fg[MB_INST + 21] = 20.0;
      uint8_t *pfg = render_rgba_pixels_of(fg, 2, 0.5, 0.5, 0.5, 2.0, aw2, ah2);
      CHECK(pfg != NULL);
      int k2_g = 0;
      if (pfg) { k2_g = W_PX(pfg, aw2, 80 * 2, 40 * 2)[1]; free(pfg); }

      double wb[6 * MB_INST];
      fill_p0_rect(wb, 0, 0, 160, 80, 0, 0.0, 0.0, 0.0, 1.0, 0);
      for (int bi = 0; bi < 4; bi++) fill_p0_rect(wb + (1 + bi) * MB_INST, 0, 10 + bi * 20, 160, 2.0, 0, 1.0, 1.0, 1.0, 1.0, 0);
      fill_p0_rect(wb + 5 * MB_INST, 14, 9, 132, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, 0x67 / 255.0, -152);
      wb[5 * MB_INST + 4] = 31.0; wb[5 * MB_INST + 6] = 1.0; wb[5 * MB_INST + 7] = 1.2;
      wb[5 * MB_INST + 12] = 0.6; wb[5 * MB_INST + 13] = 14.0;
      wb[5 * MB_INST + 15] = 1.0; wb[5 * MB_INST + 21] = 20.0;
      uint8_t *pwb = render_rgba_pixels_of(wb, 6, 0.0, 0.0, 0.0, 3.0, aw3, ah3);
      CHECK(pwb != NULL);
      int dark_bar_g = 999;
      if (pwb) { dark_bar_g = W_PX(pwb, aw3, 80 * 3, 40 * 3)[1]; free(pwb); }

      int ad_diff = 0;
      uint8_t ad_c[2][3] = {{0}};
      for (int bi = 0; bi < 2; bi++) {
        double bgv = bi ? 1.0 : 0.0;
        fill_p0_rect(fg, 0, 0, 160, 80, 0, bgv, bgv, bgv, 1.0, 0);
        fill_p0_rect(fg + MB_INST, 14, 9, 132, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, 1.0, -153 - bi);
        fg[MB_INST + 4] = 24.0; fg[MB_INST + 6] = 1.0; fg[MB_INST + 7] = 1.2;
        fg[MB_INST + 12] = 0.6; fg[MB_INST + 13] = 14.0;
        fg[MB_INST + 14] = -1.0; fg[MB_INST + 15] = 1.0; fg[MB_INST + 21] = 20.0;
        uint8_t *pad = render_rgba_pixels_of(fg, 2, bgv, bgv, bgv, 2.0, aw2, ah2);
        CHECK(pad != NULL);
        if (pad) {
          uint8_t *cad = W_PX(pad, aw2, 80 * 2, 40 * 2);
          ad_c[bi][0] = cad[0]; ad_c[bi][1] = cad[1]; ad_c[bi][2] = cad[2];
          free(pad);
        }
      }
      for (int c = 0; c < 3; c++) { int d = abs((int)ad_c[0][c] - (int)ad_c[1][c]); if (d > ad_diff) ad_diff = d; }

      uint8_t *sord[2] = {NULL, NULL};
      for (int oi = 0; oi < 2; oi++) {
        double so[4 * MB_INST];
        fill_p0_rect(so, 0, 0, 160, 80, 0, 0.95, 0.94, 0.91, 1.0, 0);
        fill_p0_rect(so + MB_INST, 0, 36, 160, 8, 0, 0.05, 0.05, 0.05, 1.0, 0);
        int li = oi == 0 ? 2 : 3, di = oi == 0 ? 3 : 2;
        fill_p0_rect(so + li * MB_INST, 8, 9, 64, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, 0x67/255.0, -156 - oi);
        so[li * MB_INST + 4] = 31.0; so[li * MB_INST + 6] = 1.0; so[li * MB_INST + 7] = 1.2;
        so[li * MB_INST + 12] = 0.6; so[li * MB_INST + 13] = 14.0;
        so[li * MB_INST + 15] = 1.0; so[li * MB_INST + 21] = 20.0;
        fill_p0_rect(so + di * MB_INST, 88, 9, 64, 62, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, 0x67/255.0, -156 - oi);
        so[di * MB_INST + 4] = 31.0; so[di * MB_INST + 6] = 1.0; so[di * MB_INST + 7] = 1.2;
        so[di * MB_INST + 12] = 0.6; so[di * MB_INST + 13] = 14.0;
        so[di * MB_INST + 15] = 1.0; so[di * MB_INST + 21] = 20.0;
        sord[oi] = render_rgba_pixels_of(so, 4, 0.95, 0.94, 0.91, 2.0, aw2, ah2);
        CHECK(sord[oi] != NULL);
      }
      int ord_diff = 0;
      if (sord[0] && sord[1]) {
        for (int i = 0; i < aw2 * ah2 * 4; i++) { int d = abs((int)sord[0][i] - (int)sord[1][i]); if (d > ord_diff) ord_diff = d; }
      }
      free(sord[0]); free(sord[1]);

      int dark_mono_ok = 1;
      double prev_dl = -1.0, dark_y20_L = 0.0, dark_y40_L = 0.0, dark_mid_L = 0.0, dark_wt_L2 = 999.0;
      for (int gi = 0; gi <= 20; gi++) {
        double gv = (double)gi / 20.0;
        fill_p0_rect(fg, 0, 0, 160, 80, 0, gv, gv, gv, 1.0, 0);
        fill_p0_rect(fg + MB_INST, 14, 9, 132, 62, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, 0x80 / 255.0, -160 - gi);
        fg[MB_INST + 4] = 24.0; fg[MB_INST + 6] = 1.0; fg[MB_INST + 7] = 14.0;
        fg[MB_INST + 12] = 0.6; fg[MB_INST + 13] = 20.0;
        fg[MB_INST + 14] = 0.0; fg[MB_INST + 15] = 1.0; fg[MB_INST + 21] = 16.0;
        uint8_t *pd = render_rgba_pixels_of(fg, 2, gv, gv, gv, 2.0, aw2, ah2);
        CHECK(pd != NULL);
        if (pd) {
          uint8_t *cd = W_PX(pd, aw2, 80 * 2, 40 * 2);
          double dl = 0.2126 * cd[0] + 0.7152 * cd[1] + 0.0722 * cd[2];
          if (prev_dl >= 0.0 && dl < prev_dl - 0.1) dark_mono_ok = 0;
          prev_dl = dl;
          if (gi == 4) dark_y20_L = dl;
          if (gi == 8) dark_y40_L = dl;
          if (gi == 11) dark_mid_L = dl;
          if (gi == 20) dark_wt_L2 = dl;
          free(pd);
        }
      }

      int light_mono_ok = 1;
      double prev_ll = -1.0, light_blk_L = 0.0, light_y60_L = 0.0, light_y80_L = 0.0;
      for (int gi = 0; gi <= 20; gi++) {
        double gv = (double)gi / 20.0;
        fill_p0_rect(fg, 0, 0, 160, 80, 0, gv, gv, gv, 1.0, 0);
        fill_p0_rect(fg + MB_INST, 14, 9, 132, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, 0x80 / 255.0, -200 - gi);
        fg[MB_INST + 4] = 24.0; fg[MB_INST + 6] = 1.0; fg[MB_INST + 7] = 14.0;
        fg[MB_INST + 12] = 0.6; fg[MB_INST + 13] = 20.0;
        fg[MB_INST + 14] = 0.0; fg[MB_INST + 15] = 1.0; fg[MB_INST + 21] = 16.0;
        uint8_t *pl = render_rgba_pixels_of(fg, 2, gv, gv, gv, 2.0, aw2, ah2);
        CHECK(pl != NULL);
        if (pl) {
          uint8_t *cl = W_PX(pl, aw2, 80 * 2, 40 * 2);
          double ll = 0.2126 * cl[0] + 0.7152 * cl[1] + 0.0722 * cl[2];
          if (prev_ll >= 0.0 && ll < prev_ll - 0.1) light_mono_ok = 0;
          prev_ll = ll;
          if (gi == 0) light_blk_L = ll;
          if (gi == 12) light_y60_L = ll;
          if (gi == 16) light_y80_L = ll;
          free(pl);
        }
      }

      double chk_cr_blk = 0.0, chk_cr_blu = 0.0;
      {
        double row_b[3 * MB_INST];
        double acc_l = 0.2126 * pow((0x98/255.0 + 0.055)/1.055, 2.4)
                     + 0.7152 * pow((0x2E/255.0 + 0.055)/1.055, 2.4)
                     + 0.0722 * ((0x01/255.0) / 12.92);
        for (int bi = 0; bi < 2; bi++) {
          double br = 0.0, bg = bi ? (0x7A/255.0) : 0.0, bb = bi ? 1.0 : 0.0;
          fill_p0_rect(row_b, 0, 0, 160, 80, 0, br, bg, bb, 1.0, 0);
          fill_p0_rect(row_b + MB_INST, 14, 9, 132, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, 0x80 / 255.0, -230 - bi);
          row_b[MB_INST + 4] = 24.0; row_b[MB_INST + 6] = 1.0; row_b[MB_INST + 7] = 14.0;
          row_b[MB_INST + 12] = 0.6; row_b[MB_INST + 13] = 20.0;
          row_b[MB_INST + 14] = 0.0; row_b[MB_INST + 15] = 1.0; row_b[MB_INST + 21] = 16.0;
          fill_p0_rect(row_b + 2 * MB_INST, 24, 22, 112, 36, 0, 0x24/255.0, 0x27/255.0, 0x2B/255.0, 0x0F / 255.0, 0);
          row_b[2 * MB_INST + 4] = 14.0;
          uint8_t *pr = render_rgba_pixels_of(row_b, 3, br, bg, bb, 2.0, aw2, ah2);
          CHECK(pr != NULL);
          if (pr) {
            uint8_t *crp = W_PX(pr, aw2, 80 * 2, 40 * 2);
            double cr_r = crp[0] / 255.0, cr_g = crp[1] / 255.0, cr_b = crp[2] / 255.0;
            double lr = (cr_r <= 0.04045) ? cr_r / 12.92 : pow((cr_r + 0.055) / 1.055, 2.4);
            double lg = (cr_g <= 0.04045) ? cr_g / 12.92 : pow((cr_g + 0.055) / 1.055, 2.4);
            double lb = (cr_b <= 0.04045) ? cr_b / 12.92 : pow((cr_b + 0.055) / 1.055, 2.4);
            double row_l = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb;
            double hi = row_l > acc_l ? row_l : acc_l, lo = row_l > acc_l ? acc_l : row_l;
            double crv = (hi + 0.05) / (lo + 0.05);
            if (bi == 0) chk_cr_blk = crv; else chk_cr_blu = crv;
            free(pr);
          }
        }
      }

      int shw = 200 * 3, shh = 160 * 3;
      double sh[3 * MB_INST];
      fill_p0_rect(sh, 0, 0, 200, 160, 0, 244.0/255.0, 241.0/255.0, 234.0/255.0, 1.0, 0);
      fill_p0_rect(sh + MB_INST, 20, 40 + 6, 160, 100, 2, 0.0, 0.0, 0.0, 0x18 / 255.0, 0);
      sh[MB_INST + 4] = 24.0; sh[MB_INST + 7] = 14.0;
      sh[MB_INST + 12] = 1.0; sh[MB_INST + 13] = 6.0;
      sh[MB_INST + 18] = 200.0; sh[MB_INST + 19] = 160.0;
      sh[MB_INST + 36] = 24.0; sh[MB_INST + 37] = 24.0; sh[MB_INST + 38] = 24.0; sh[MB_INST + 39] = 24.0;
      fill_p0_rect(sh + 2 * MB_INST, 20, 40, 160, 100, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, 0x80 / 255.0, -190);
      sh[2 * MB_INST + 4] = 24.0; sh[2 * MB_INST + 6] = 1.0; sh[2 * MB_INST + 7] = 14.0;
      sh[2 * MB_INST + 12] = 0.6; sh[2 * MB_INST + 13] = 20.0;
      sh[2 * MB_INST + 15] = 1.0; sh[2 * MB_INST + 18] = 200.0; sh[2 * MB_INST + 19] = 160.0; sh[2 * MB_INST + 21] = 16.0;
      sh[2 * MB_INST + 36] = 24.0; sh[2 * MB_INST + 37] = 24.0; sh[2 * MB_INST + 38] = 24.0; sh[2 * MB_INST + 39] = 24.0;
      uint8_t *psh = render_rgba_pixels_of(sh, 3, 244.0/255.0, 241.0/255.0, 234.0/255.0, 3.0, shw, shh);
      CHECK(psh != NULL);
      double sh_max_jump = 999.0;
      if (psh) {
        sh_max_jump = 0.0;
        double sh_prev = -1.0;
        for (int py = 60; py <= 114; py++) {
          uint8_t *sp = W_PX(psh, shw, 100 * 3, py);
          double sl = 0.2126 * sp[0] + 0.7152 * sp[1] + 0.0722 * sp[2];
          if (sh_prev >= 0.0 && (sl - sh_prev) > sh_max_jump) sh_max_jump = sl - sh_prev;
          sh_prev = sl;
        }
        free(psh);
      }
      printf("win_gpu: v15_unified_v9 k2_g=%d dark_bar_g=%d ad_ff_diff=%d ord_diff=%d dark_mono=%d d20=%.1f d40=%.1f mid55=%.1f wt=%.1f light_mono=%d blk=%.1f l60=%.1f l80=%.1f chk_blk=%.2f chk_blu=%.2f sh_jump=%.2f\n",
             k2_g, dark_bar_g, ad_diff, ord_diff, dark_mono_ok, dark_y20_L, dark_y40_L, dark_mid_L, dark_wt_L2, light_mono_ok, light_blk_L, light_y60_L, light_y80_L, chk_cr_blk, chk_cr_blu, sh_max_jump);
      CHECK(abs(k2_g - 195) <= 2);
      CHECK(dark_bar_g <= 150);
      CHECK(ad_diff <= 1);
      CHECK(ord_diff == 0);
      CHECK(dark_mono_ok == 1 && dark_wt_L2 <= 102.0 && (dark_wt_L2 - dark_y40_L) >= 6.0 && (dark_wt_L2 - dark_y20_L) >= 24.0);
      CHECK(light_mono_ok == 1 && light_blk_L >= 198.0 && (light_y60_L - light_blk_L) >= 10.0 && (light_y80_L - light_blk_L) >= 26.0);
      CHECK(chk_cr_blk >= 3.0 && chk_cr_blu >= 3.0);
      CHECK(sh_max_jump < 2.5);
    }
  }
  #undef W_PX
}

static void test_perf51_donor_and_provoking_vertex(void) {
  const int VW = 200, VH = 160;
  const int PW = VW * 2, PH = VH * 2;
  #define P51_PX(buf, w, xpx, ypx) ((buf) + ((size_t)(ypx) * (size_t)(w) + (size_t)(xpx)) * 4u)
  auto fill_unit_sq_segs = [](double *d) {
    memset(d, 0, MB_INST * sizeof(double));
    d[5] = 12.0;
    d[0] = 0.0; d[1] = 0.0; d[2] = 1.0; d[3] = 0.0;
    d[8] = 1.0; d[9] = 0.0; d[10] = 1.0; d[11] = 1.0;
    d[12] = 1.0; d[13] = 1.0; d[14] = 0.0; d[15] = 1.0;
    d[16] = 0.0; d[17] = 1.0; d[18] = 0.0; d[19] = 0.0;
  };
  auto wcag_y = [](uint8_t r, uint8_t g, uint8_t b) {
    auto lin = [](double c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); };
    return 0.2126 * lin(r / 255.0) + 0.7152 * lin(g / 255.0) + 0.0722 * lin(b / 255.0);
  };

  // (a) Top-bar pure progressive donor delegation hit, tight grab_of_with_donors < raw grab_of, CR >= 4.5, backdrop restored
  for (int dark_bg = 0; dark_bg <= 1; dark_bg++) {
    double bgv = dark_bg ? 0.06 : 0.94;
    double tb[5 * MB_INST];
    fill_p0_rect(tb, 0, 0, VW, VH, 0, bgv, bgv, bgv, 1.0, 0);
    fill_p0_rect(tb + MB_INST, 0, 0, VW, 56, 5, 0, 0, 0, 0.0, -301);
    tb[MB_INST + 6] = 1.0; tb[MB_INST + 7] = 6.0; tb[MB_INST + 15] = 1.0;
    tb[MB_INST + 22] = -1.0; tb[MB_INST + 54] = 56.0; tb[MB_INST + 55] = 24.0;
    fill_p0_rect(tb + 2 * MB_INST, 8, 12, 24, 24, 6, 0.14, 0.14, 0.15, 0.4, -302);
    tb[2 * MB_INST + 4] = 12.0; tb[2 * MB_INST + 6] = 1.0; tb[2 * MB_INST + 7] = 1.4;
    tb[2 * MB_INST + 14] = -1.0; tb[2 * MB_INST + 15] = 1.0;
    tb[2 * MB_INST + 21] = 4.0; tb[2 * MB_INST + 23] = 2.0;
    // Bare-adaptive title path (kind 11 filled square at x=100..124, y=14..38)
    fill_p0_rect(tb + 3 * MB_INST, 100, 14, 24, 24, 11, 0.9, 0.9, 0.9, 1.0, 0);
    tb[3 * MB_INST + 4] = 0.0; tb[3 * MB_INST + 12] = 0.0; tb[3 * MB_INST + 13] = 4.0;
    tb[3 * MB_INST + 23] = -16.0;
    fill_unit_sq_segs(tb + 4 * MB_INST);
    uint8_t *px = render_rgba_pixels_of(tb, 5, bgv, bgv, bgv, 2.0, PW, PH);
    CHECK(px != NULL);
    CHECK(donor_delegated_count == 1);
    CHECK(donor_of_buf && donor_of_buf[3] == -301);
    float f_tmp[5 * MB_INST];
    for (int i = 0; i < 5 * MB_INST; i++) f_tmp[i] = (float)tb[i];
    Grab gm_del, gm_raw;
    double saved_vscale = vscale;
    vscale = 2.0;
    CHECK(grab_of_with_donors(&gm_del, f_tmp, 2, 3, 5, PW, PH, donor_of_buf) == 1);
    CHECK(grab_of(&gm_raw, f_tmp, 2, 3, 5, PW, PH) == 1);
    vscale = saved_vscale;
    CHECK(gm_del.w < gm_raw.w);
    if (px) {
      uint8_t *tp = P51_PX(px, PW, 112 * 2, 26 * 2);
      double y_fg = wcag_y(tp[0], tp[1], tp[2]);
      double y_bg = wcag_y((uint8_t)(bgv * 255.0 + 0.5), (uint8_t)(bgv * 255.0 + 0.5), (uint8_t)(bgv * 255.0 + 0.5));
      double cr = ((y_fg > y_bg ? y_fg : y_bg) + 0.05) / ((y_fg > y_bg ? y_bg : y_fg) + 0.05);
      CHECK(cr >= 4.5);
      free(px);
    }
  }

  // (b) 33rd cold capture donor pin over opposite-brightness white filler region (0 LSB diff on title)
  {
    double ref[6 * MB_INST];
    fill_p0_rect(ref, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 1.0, 0);
    fill_p0_rect(ref + MB_INST, 60, 0, VW - 60, 60, 0, 0.05, 0.05, 0.05, 1.0, 0);
    fill_p0_rect(ref + 2 * MB_INST, 0, 0, VW, 56, 5, 0, 0, 0, 0.0, -310);
    ref[2 * MB_INST + 6] = 1.0; ref[2 * MB_INST + 7] = 6.0; ref[2 * MB_INST + 15] = 1.0;
    ref[2 * MB_INST + 22] = -1.0; ref[2 * MB_INST + 54] = 56.0; ref[2 * MB_INST + 55] = 24.0;
    fill_p0_rect(ref + 3 * MB_INST, 8, 12, 24, 24, 6, 0.14, 0.14, 0.15, 0.4, -311);
    ref[3 * MB_INST + 4] = 12.0; ref[3 * MB_INST + 6] = 1.0; ref[3 * MB_INST + 7] = 1.4;
    ref[3 * MB_INST + 14] = -1.0; ref[3 * MB_INST + 15] = 1.0;
    ref[3 * MB_INST + 21] = 4.0; ref[3 * MB_INST + 23] = 2.0;
    fill_p0_rect(ref + 4 * MB_INST, 100, 14, 24, 24, 11, 0.2, 0.2, 0.2, 1.0, 0);
    ref[4 * MB_INST + 4] = 0.0; ref[4 * MB_INST + 12] = 0.0; ref[4 * MB_INST + 13] = 4.0;
    ref[4 * MB_INST + 23] = -16.0;
    fill_unit_sq_segs(ref + 5 * MB_INST);
    uint8_t *ref_px = render_rgba_pixels_of(ref, 6, 1.0, 1.0, 1.0, 2.0, PW, PH);
    CHECK(ref_px != NULL);

    double *st = (double *)calloc(37 * MB_INST, sizeof(double));
    memcpy(st, ref, 3 * MB_INST * sizeof(double));
    for (int i = 0; i < 31; i++) {
      double *g = st + (size_t)(3 + i) * MB_INST;
      fill_p0_rect(g, 4 + (i % 10) * 19, 64 + (i / 10) * 22, 14, 14, 5, 0.5, 0.5, 0.5, 0.2, (double)(-(320 + i)));
      g[6] = 1.0; g[7] = 2.0; g[15] = 1.0;
    }
    memcpy(st + 34 * MB_INST, ref + 3 * MB_INST, 3 * MB_INST * sizeof(double));
    slots_invalidate();
    unsigned clk0 = gslots_clock;
    uint8_t *st_px = render_rgba_pixels_of(st, 37, 1.0, 1.0, 1.0, 2.0, PW, PH);
    CHECK(st_px != NULL);
    CHECK(donor_delegated_count == 1);
    CHECK(gslots_clock - clk0 >= 33u);
    if (ref_px && st_px) {
      for (int y = 16 * 2; y < 36 * 2; y++) {
        for (int x = 102 * 2; x < 122 * 2; x++) {
          uint8_t *a = P51_PX(ref_px, PW, x, y);
          uint8_t *b = P51_PX(st_px, PW, x, y);
          CHECK(a[0] == b[0] && a[1] == b[1] && a[2] == b[2]);
        }
      }
      uint8_t *tc = P51_PX(st_px, PW, 112 * 2, 26 * 2);
      CHECK(tc[0] > 180 && tc[1] > 180 && tc[2] > 180);
    }
    free(ref_px); free(st_px); free(st);
  }

  // (c) kind == 8 lens subtree counterexample (donor_delegated_count == 0)
  {
    double ln[6 * MB_INST];
    fill_p0_rect(ln, 0, 0, VW, VH, 0, 0.05, 0.05, 0.05, 1.0, 0);
    fill_p0_rect(ln + MB_INST, 0, 0, VW, 56, 8, 1, 1, 1, 1.0, 0);
    ln[MB_INST + 7] = 2.0; ln[MB_INST + 12] = 1.0; ln[MB_INST + 15] = 1.0;
    fill_p0_rect(ln + 2 * MB_INST, 0, 0, VW, 56, 5, 0, 0, 0, 0.0, -360);
    ln[2 * MB_INST + 6] = 1.0; ln[2 * MB_INST + 7] = 6.0; ln[2 * MB_INST + 15] = 1.0;
    ln[2 * MB_INST + 22] = -1.0; ln[2 * MB_INST + 54] = 56.0; ln[2 * MB_INST + 55] = 24.0;
    fill_p0_rect(ln + 3 * MB_INST, 8, 12, 24, 24, 6, 0.14, 0.14, 0.15, 0.4, -361);
    ln[3 * MB_INST + 4] = 12.0; ln[3 * MB_INST + 6] = 1.0; ln[3 * MB_INST + 7] = 1.4;
    ln[3 * MB_INST + 14] = -1.0; ln[3 * MB_INST + 15] = 1.0;
    ln[3 * MB_INST + 21] = 4.0; ln[3 * MB_INST + 23] = 2.0;
    fill_p0_rect(ln + 4 * MB_INST, 100, 14, 24, 24, 11, 0.2, 0.2, 0.2, 1.0, 0);
    ln[4 * MB_INST + 4] = 0.0; ln[4 * MB_INST + 12] = 0.0; ln[4 * MB_INST + 13] = 4.0;
    ln[4 * MB_INST + 23] = -16.0;
    fill_unit_sq_segs(ln + 5 * MB_INST);
    uint8_t *px = render_rgba_pixels_of(ln, 6, 0.05, 0.05, 0.05, 2.0, PW, PH);
    CHECK(px != NULL);
    CHECK(donor_delegated_count == 0);
    free(px);
  }

  // (d) vid == 0u || vid == 3u provoking-vertex both-triangles verification
  {
    double pv[4 * MB_INST];
    fill_p0_rect(pv, 0, 0, VW, VH, 0, 0.05, 0.05, 0.05, 1.0, 0);
    fill_p0_rect(pv + MB_INST, 0, 0, VW, VH, 5, 0, 0, 0, 0.0, -370);
    pv[MB_INST + 6] = 1.0; pv[MB_INST + 7] = 4.0; pv[MB_INST + 15] = 1.0;
    pv[MB_INST + 22] = -1.0; pv[MB_INST + 54] = (double)VH; pv[MB_INST + 55] = 10.0;
    // Large dark bare-adaptive filled square (20..160, 20..120): both triangle 0 (upper-left) & triangle 1 (lower-right) must invert bright!
    fill_p0_rect(pv + 2 * MB_INST, 20, 20, 140, 100, 11, 0.15, 0.15, 0.15, 1.0, 0);
    pv[2 * MB_INST + 4] = 0.0; pv[2 * MB_INST + 12] = 0.0; pv[2 * MB_INST + 13] = 4.0;
    pv[2 * MB_INST + 23] = -16.0;
    fill_unit_sq_segs(pv + 3 * MB_INST);
    uint8_t *px = render_rgba_pixels_of(pv, 4, 0.05, 0.05, 0.05, 2.0, PW, PH);
    CHECK(px != NULL);
    if (px) {
      uint8_t *tri0 = P51_PX(px, PW, 40 * 2, 35 * 2);
      uint8_t *tri1 = P51_PX(px, PW, 140 * 2, 105 * 2);
      CHECK(tri0[0] == tri1[0] && tri0[1] == tri1[1] && tri0[2] == tri1[2]);
      CHECK(tri0[0] > 180 && tri0[1] > 180 && tri0[2] > 180);
      free(px);
    }
  }
  #undef P51_PX
  printf("win_gpu: perf-51 ok\n");
}

static void test_liquid_over_hole(void) {
  const int VW = 400, VH = 300;
  const int PW = VW * 2, PH = VH * 2;
  double lh[2 * MB_INST];

  // Light liquid_panel_glass (0xfdfcfd80) over a kind == 9 native-view hole:
  // translucent premultiplied output (rgb <= a, a in 132..156) so video composites through.
  fill_p0_rect(lh, 0, 0, VW, VH, 9, 0, 0, 0, 0, 8388608.0 + 7.0);
  fill_p0_rect(lh + MB_INST, 40, 80, 320, 120, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 128.0 / 255.0, -390);
  lh[MB_INST + 4] = 26.0; lh[MB_INST + 6] = 1.0; lh[MB_INST + 7] = 8.0;
  lh[MB_INST + 12] = 0.55; lh[MB_INST + 13] = 14.0; lh[MB_INST + 15] = 1.0;
  lh[MB_INST + 21] = 14.0; lh[MB_INST + 22] = 0.08;
  uint8_t *px_l = render_rgba_pixels_of(lh, 2, 0.0, 0.0, 0.0, 2.0, PW, PH);
  CHECK(px_l != NULL);
  if (px_l) {
    const uint8_t *c = px_l + ((size_t)280 * (size_t)PW + 400u) * 4u;
    int lr = c[0], lg = c[1], lb = c[2], la = c[3];
    printf("win_gpu: liquid-over-hole light raw=(%d,%d,%d,a=%d)\n", lr, lg, lb, la);
    CHECK(la >= 132 && la <= 156);
    CHECK(lr <= la && lg <= la && lb <= la);
    free(px_l);
  }

  // Dark liquid_panel_glass (0x20202080) over hole: translucent (a in 180..205), over-white <= 105.
  lh[MB_INST + 8] = 32.0 / 255.0; lh[MB_INST + 9] = 32.0 / 255.0; lh[MB_INST + 10] = 32.0 / 255.0;
  lh[MB_INST + 11] = 128.0 / 255.0; lh[MB_INST + 20] = -391.0;
  uint8_t *px_d = render_rgba_pixels_of(lh, 2, 0.0, 0.0, 0.0, 2.0, PW, PH);
  CHECK(px_d != NULL);
  if (px_d) {
    const uint8_t *c = px_d + ((size_t)280 * (size_t)PW + 400u) * 4u;
    int dr = c[0], dg = c[1], db = c[2], da = c[3];
    int over_w = dr + (255 * (255 - da) + 127) / 255;
    printf("win_gpu: liquid-over-hole dark raw=(%d,%d,%d,a=%d) over-white=%d\n", dr, dg, db, da, over_w);
    CHECK(da >= 180 && da <= 205);
    CHECK(dr <= da && dg <= da && db <= da);
    CHECK(over_w <= 105);
    free(px_d);
  }

  // Opaque canvas (no kind == 9 hole): stays fully opaque (a == 255).
  fill_p0_rect(lh, 0, 0, VW, VH, 0, 0, 0, 0, 1.0, 0);
  lh[MB_INST + 8] = 253.0 / 255.0; lh[MB_INST + 9] = 252.0 / 255.0; lh[MB_INST + 10] = 253.0 / 255.0;
  lh[MB_INST + 11] = 128.0 / 255.0; lh[MB_INST + 20] = -392.0;
  uint8_t *px_o = render_rgba_pixels_of(lh, 2, 0.0, 0.0, 0.0, 2.0, PW, PH);
  CHECK(px_o != NULL);
  if (px_o) {
    const uint8_t *c = px_o + ((size_t)280 * (size_t)PW + 400u) * 4u;
    CHECK(c[3] == 255);
    free(px_o);
  }

  // v10_through_hole_adaptive_ink: adaptive Light liquid glass over a real kind==9 native-view hole
  // keeps light glass + dark icon (kind==10) + dark opaque adaptive_ink progress bar (kind==0, pad.w<0),
  // while an identical capsule on the opaque pure black stage (a==1) flips to dark glass + bright white ink,
  // and a capsule over a 70% dark scrim (rgba(0,0,0,0.70)) atop the kind==9 hole flips its ink bright white.
  {
    const int TW = 400, TH = 240, TPW = TW * 2, TPH = TH * 2;
    double th[11 * MB_INST];
    fill_p0_rect(th + 0 * MB_INST, 0, 0, TW, TH, 0, 0.0, 0.0, 0.0, 1.0, 0);
    fill_p0_rect(th + 1 * MB_INST, 0, 0, 200, TH, 9, 0.0, 0.0, 0.0, 0.0, 8388608.0 + 7.0);
    // Capsule A over raw kind==9 hole: (20, 36, 160, 48), center (100, 60)
    fill_p0_rect(th + 2 * MB_INST, 20, 36, 160, 48, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 0x67 / 255.0, -393.0);
    th[2 * MB_INST + 4] = 24.0; th[2 * MB_INST + 6] = 1.0; th[2 * MB_INST + 7] = 2.0;
    th[2 * MB_INST + 12] = 0.0; th[2 * MB_INST + 13] = 14.0; th[2 * MB_INST + 14] = -1.0; th[2 * MB_INST + 15] = 1.0;
    // Capsule A icon (kind==10, 0x18181BFF) at center (56, 60)
    fill_p0_rect(th + 3 * MB_INST, 44, 50, 24, 20, 10, 24.0 / 255.0, 24.0 / 255.0, 27.0 / 255.0, 1.0, 0);
    th[3 * MB_INST + 4] = 6.0;
    th[3 * MB_INST + 12] = 0.1; th[3 * MB_INST + 13] = 0.5; th[3 * MB_INST + 14] = 0.9; th[3 * MB_INST + 15] = 0.5;
    th[3 * MB_INST + 21] = 100.0; th[3 * MB_INST + 22] = 60.0; th[3 * MB_INST + 23] = 48.0;
    // Capsule A opaque adaptive_ink progress bar (kind==0, pad.w=-48, 0x18181BFF) at center (134, 60)
    fill_p0_rect(th + 4 * MB_INST, 104, 52, 60, 16, 0, 24.0 / 255.0, 24.0 / 255.0, 27.0 / 255.0, 1.0, 0);
    th[4 * MB_INST + 4] = 8.0;
    th[4 * MB_INST + 21] = 100.0; th[4 * MB_INST + 22] = 60.0; th[4 * MB_INST + 23] = -48.0;
    // Capsule B over opaque pure black stage: (220, 36, 160, 48), center (300, 60)
    fill_p0_rect(th + 5 * MB_INST, 220, 36, 160, 48, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 0x67 / 255.0, -394.0);
    th[5 * MB_INST + 4] = 24.0; th[5 * MB_INST + 6] = -1.0; th[5 * MB_INST + 7] = 2.0;
    th[5 * MB_INST + 12] = 0.0; th[5 * MB_INST + 13] = 14.0; th[5 * MB_INST + 14] = -1.0; th[5 * MB_INST + 15] = 1.0;
    // Capsule B icon (kind==10, 0x18181BFF) at center (256, 60)
    fill_p0_rect(th + 6 * MB_INST, 244, 50, 24, 20, 10, 24.0 / 255.0, 24.0 / 255.0, 27.0 / 255.0, 1.0, 0);
    th[6 * MB_INST + 4] = 6.0;
    th[6 * MB_INST + 12] = 0.1; th[6 * MB_INST + 13] = 0.5; th[6 * MB_INST + 14] = 0.9; th[6 * MB_INST + 15] = 0.5;
    th[6 * MB_INST + 21] = 300.0; th[6 * MB_INST + 22] = 60.0; th[6 * MB_INST + 23] = 48.0;
    // Capsule B opaque adaptive_ink progress bar (kind==0, pad.w=-48, 0x18181BFF) at center (334, 60)
    fill_p0_rect(th + 7 * MB_INST, 304, 52, 60, 16, 0, 24.0 / 255.0, 24.0 / 255.0, 27.0 / 255.0, 1.0, 0);
    th[7 * MB_INST + 4] = 8.0;
    th[7 * MB_INST + 21] = 300.0; th[7 * MB_INST + 22] = 60.0; th[7 * MB_INST + 23] = -48.0;
    // 70% dark scrim (rgba(0,0,0,0.70)) over bottom-left kind==9 hole: (10, 150, 180, 70)
    fill_p0_rect(th + 8 * MB_INST, 10, 150, 180, 70, 0, 0.0, 0.0, 0.0, 0.70, 0);
    // Capsule C over 70% dark scrim on kind==9 hole: (20, 160, 160, 50), center (100, 185)
    fill_p0_rect(th + 9 * MB_INST, 20, 160, 160, 50, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 0x67 / 255.0, -395.0);
    th[9 * MB_INST + 4] = 24.0; th[9 * MB_INST + 6] = -1.0; th[9 * MB_INST + 7] = 2.0;
    th[9 * MB_INST + 12] = 0.0; th[9 * MB_INST + 13] = 14.0; th[9 * MB_INST + 14] = -1.0; th[9 * MB_INST + 15] = 1.0;
    // Capsule C dark adaptive ink (kind==10, #1A1A1A) at center (100, 185)
    fill_p0_rect(th + 10 * MB_INST, 88, 175, 24, 20, 10, 26.0 / 255.0, 26.0 / 255.0, 26.0 / 255.0, 1.0, 0);
    th[10 * MB_INST + 4] = 6.0;
    th[10 * MB_INST + 12] = 0.1; th[10 * MB_INST + 13] = 0.5; th[10 * MB_INST + 14] = 0.9; th[10 * MB_INST + 15] = 0.5;
    th[10 * MB_INST + 21] = 100.0; th[10 * MB_INST + 22] = 185.0; th[10 * MB_INST + 23] = 50.0;
    // Render via stateful submit() (ad_mode = 1) matching Apple/GLES live presentation so adaptive slots
    // drive clear-invert (Capsule B/C) while unslotted stateless shots stay same-polarity.
    D3D11_TEXTURE2D_DESC th_td = {};
    th_td.Width = (UINT)TPW;
    th_td.Height = (UINT)TPH;
    th_td.MipLevels = th_td.ArraySize = 1;
    th_td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    th_td.SampleDesc.Count = 1;
    th_td.Usage = D3D11_USAGE_DEFAULT;
    th_td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    ID3D11Texture2D *th_tex = NULL;
    ID3D11RenderTargetView *th_rtv = NULL;
    CHECK(SUCCEEDED(dev->CreateTexture2D(&th_td, NULL, &th_tex)) && th_tex != NULL);
    if (th_tex) CHECK(SUCCEEDED(dev->CreateRenderTargetView(th_tex, NULL, &th_rtv)) && th_rtv != NULL);
    uint8_t *px_th = NULL;
    if (th_tex && th_rtv) {
      ID3D11RenderTargetView *saved_rtv = rtv;
      ID3D11Texture2D *saved_off = off_target;
      double saved_vw = vw, saved_vh = vh, saved_vscale = vscale;
      int saved_fb_w = fb_w, saved_fb_h = fb_h, saved_ad_mode = ad_mode;
      rtv = th_rtv;
      off_target = th_tex;
      vw = (double)TW;
      vh = (double)TH;
      vscale = 2.0;
      fb_w = TPW;
      fb_h = TPH;
      off_ok = 0;
      dirty_whole = 1;
      glass_free();
      ad_mode = 1;
      ad_cur_dt = 1.0 / 60.0;
      if (rw) {
        rw->ad_frame_serial = 0;
        memset(rw->ad_slots, 0, sizeof rw->ad_slots);
      }
      CHECK(submit(th, 11, 0.0, 0.0, 0.0) == 1);
      ctx->Flush();
      th_td.Usage = D3D11_USAGE_STAGING;
      th_td.BindFlags = 0;
      th_td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      ID3D11Texture2D *th_stg = NULL;
      if (SUCCEEDED(dev->CreateTexture2D(&th_td, NULL, &th_stg)) && th_stg) {
        ctx->CopyResource(th_stg, th_tex);
        D3D11_MAPPED_SUBRESOURCE m = {};
        if (SUCCEEDED(ctx->Map(th_stg, 0, D3D11_MAP_READ, 0, &m))) {
          px_th = (uint8_t *)malloc((size_t)TPW * (size_t)TPH * 4u);
          if (px_th) {
            for (int y = 0; y < TPH; y++) {
              const uint8_t *s = (const uint8_t *)m.pData + (size_t)y * (size_t)m.RowPitch;
              uint8_t *d = px_th + (size_t)y * (size_t)TPW * 4u;
              for (int x = 0; x < TPW; x++, s += 4, d += 4) {
                d[0] = s[2];
                d[1] = s[1];
                d[2] = s[0];
                d[3] = s[3];
              }
            }
          }
          ctx->Unmap(th_stg, 0);
        }
        th_stg->Release();
      }
      ad_cur_dt = 0.0;
      ad_mode = saved_ad_mode;
      glass_free();
      rtv = saved_rtv;
      off_target = saved_off;
      vw = saved_vw;
      vh = saved_vh;
      vscale = saved_vscale;
      fb_w = saved_fb_w;
      fb_h = saved_fb_h;
      off_ok = 0;
      dirty_whole = 1;
    }
    if (th_rtv) th_rtv->Release();
    if (th_tex) th_tex->Release();
    CHECK(px_th != NULL);
    if (px_th) {
      const uint8_t *a_gl = px_th + ((size_t)(60 * 2) * (size_t)TPW + 84u * 2u) * 4u;
      const uint8_t *a_tx = px_th + ((size_t)(60 * 2) * (size_t)TPW + 56u * 2u) * 4u;
      const uint8_t *a_br = px_th + ((size_t)(60 * 2) * (size_t)TPW + 134u * 2u) * 4u;
      const uint8_t *b_gl = px_th + ((size_t)(60 * 2) * (size_t)TPW + 284u * 2u) * 4u;
      const uint8_t *b_tx = px_th + ((size_t)(60 * 2) * (size_t)TPW + 256u * 2u) * 4u;
      const uint8_t *b_br = px_th + ((size_t)(60 * 2) * (size_t)TPW + 334u * 2u) * 4u;
      const uint8_t *c_tx = px_th + ((size_t)(185 * 2) * (size_t)TPW + 100u * 2u) * 4u;
      double a_tx_l = (0.2126 * a_tx[0] + 0.7152 * a_tx[1] + 0.0722 * a_tx[2]) / 255.0;
      double a_br_l = (0.2126 * a_br[0] + 0.7152 * a_br[1] + 0.0722 * a_br[2]) / 255.0;
      double b_gl_l = (0.2126 * b_gl[0] + 0.7152 * b_gl[1] + 0.0722 * b_gl[2]) / 255.0;
      double b_tx_l = (0.2126 * b_tx[0] + 0.7152 * b_tx[1] + 0.0722 * b_tx[2]) / 255.0;
      double b_br_l = (0.2126 * b_br[0] + 0.7152 * b_br[1] + 0.0722 * b_br[2]) / 255.0;
      double c_tx_l = (0.2126 * c_tx[0] + 0.7152 * c_tx[1] + 0.0722 * c_tx[2]) / 255.0;
      printf("win_gpu: v10_through_hole_adaptive_ink hole=(gl=%u/%u tx=%.3f br=%.3f) stage=(gl=%.3f tx=%.3f br=%.3f) scrim70=(tx=%.3f)\n",
             a_gl[0], a_gl[3], a_tx_l, a_br_l, b_gl_l, b_tx_l, b_br_l, c_tx_l);
      CHECK(a_gl[3] >= 100 && a_gl[3] <= 170 && a_gl[0] >= a_gl[3] - 12);
      CHECK(a_tx_l < 0.25 && a_br_l < 0.25);
      CHECK(b_gl[3] == 255 && b_gl_l < 0.35);
      CHECK(b_tx_l > 0.75 && b_br_l > 0.75);
      CHECK(c_tx_l > 0.75);
      free(px_th);
    }
    // Unslotted stateless fallback (ad_mode = -1): inverting light glass must stay same-polarity
    // (light glass + dark ink) rather than dark glass + dark ink.
    uint8_t *px_fb = render_rgba_pixels_of(th, 11, 0.0, 0.0, 0.0, 2.0, TPW, TPH);
    CHECK(px_fb != NULL);
    if (px_fb) {
      const uint8_t *b_gl = px_fb + ((size_t)(60 * 2) * (size_t)TPW + 284u * 2u) * 4u;
      const uint8_t *b_tx = px_fb + ((size_t)(60 * 2) * (size_t)TPW + 256u * 2u) * 4u;
      double b_gl_l = (0.2126 * b_gl[0] + 0.7152 * b_gl[1] + 0.0722 * b_gl[2]) / 255.0;
      double b_tx_l = (0.2126 * b_tx[0] + 0.7152 * b_tx[1] + 0.0722 * b_tx[2]) / 255.0;
      printf("win_gpu: v10_unslotted_inverting_fallback stage=(gl=%.3f tx=%.3f)\n", b_gl_l, b_tx_l);
      CHECK(b_gl_l > 0.50);
      CHECK(b_tx_l < 0.25);
      free(px_fb);
    }
  }
}

static void test_perf59_cull_and_donor(void) {
  // (a) encode_rects() partial-redraw CPU scissor culling, lens culling, single-pass segs_upload, lazy multi-rect
  //     glass pre_hits (with stale-gen in-place refresh), and bit-exact WARP pixel parity vs whole-frame redraw.
  {
    auto read_offscreen_bgra = [](int w, int h) -> uint8_t * {
      if (!dev || !ctx || !off_target) return NULL;
      D3D11_TEXTURE2D_DESC td = {};
      off_target->GetDesc(&td);
      if ((int)td.Width != w || (int)td.Height != h) return NULL;
      td.Usage = D3D11_USAGE_STAGING;
      td.BindFlags = 0;
      td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      td.MiscFlags = 0;
      ID3D11Texture2D *staging = NULL;
      if (FAILED(dev->CreateTexture2D(&td, NULL, &staging))) return NULL;
      ctx->CopyResource(staging, off_target);
      D3D11_MAPPED_SUBRESOURCE m = {};
      uint8_t *out = NULL;
      if (SUCCEEDED(ctx->Map(staging, 0, D3D11_MAP_READ, 0, &m))) {
        out = (uint8_t *)malloc((size_t)w * (size_t)h * 4u);
        if (out) {
          for (int y = 0; y < h; y++) {
            memcpy(out + (size_t)y * (size_t)w * 4u, (const uint8_t *)m.pData + (size_t)y * (size_t)m.RowPitch,
                   (size_t)w * 4u);
          }
        }
        ctx->Unmap(staging, 0);
      }
      staging->Release();
      return out;
    };

    const int W = 128, H = 128;
    const double saved_vw = vw, saved_vh = vh, saved_vscale = vscale;
    const int saved_fb_w = fb_w, saved_fb_h = fb_h;
    vw = (double)W;
    vh = (double)H;
    vscale = 1.0;
    fb_w = W;
    fb_h = H;
    const int N_GRID = 180;
    const int TOTAL = N_GRID + 5;  // 180 rects + 1 frosted glass + 1 lens(header+child) + 1 path + 1 seg
    double *sc = (double *)calloc((size_t)TOTAL * MB_INST, sizeof(double));
    CHECK(sc != NULL);
    if (sc) {
      int idx = 0;
      // 180 small rects distributed across 128x128 (mostly outside the bottom-left / top-left dirty rects).
      for (int i = 0; i < N_GRID; i++) {
        int col = i % 15;
        int row = i / 15;
        double rx = 4.0 + (double)col * 8.0;
        double ry = 4.0 + (double)row * 10.0;
        fill_p0_rect(sc + (size_t)idx * MB_INST, rx, ry, 6.0, 6.0, 0.0,
                     0.15 + 0.05 * (col % 10), 0.25 + 0.04 * (row % 10), 0.70, 1.0, 0.0);
        idx++;
      }
      // Frosted glass panel spanning x=[8, 88], y=[8, 32] (tid = -590, blur = 1.0)
      int glass_idx = idx++;
      fill_p0_rect(sc + (size_t)glass_idx * MB_INST, 8.0, 8.0, 80.0, 24.0, 5.0, 0.9, 0.9, 0.95, 0.35, -590.0);
      sc[(size_t)glass_idx * MB_INST + 6] = 1.0;
      sc[(size_t)glass_idx * MB_INST + 7] = 1.0;
      sc[(size_t)glass_idx * MB_INST + 15] = 1.0;
      // kind == 8 lens at bottom-right (84, 84, 36, 36) with 1 child rect (must be culled when dirty rects are left)
      int lens_idx = idx++;
      fill_p0_rect(sc + (size_t)lens_idx * MB_INST, 84.0, 84.0, 36.0, 36.0, 8.0, 1.0, 1.0, 1.0, 1.0, 0.0);
      sc[(size_t)lens_idx * MB_INST + 7] = 2.0;
      sc[(size_t)lens_idx * MB_INST + 12] = 1.0;
      sc[(size_t)lens_idx * MB_INST + 15] = 1.0;
      int lens_child = idx++;
      fill_p0_rect(sc + (size_t)lens_child * MB_INST, 92.0, 92.0, 20.0, 20.0, 0.0, 0.95, 0.35, 0.15, 1.0, 0.0);
      // kind == 11 filled path at bottom-left (16, 88, 24, 24) + kind == 12 segment trailer
      int path_idx = idx++;
      fill_p0_rect(sc + (size_t)path_idx * MB_INST, 16.0, 88.0, 24.0, 24.0, 11.0, 0.90, 0.80, 0.20, 1.0, 0.0);
      sc[(size_t)path_idx * MB_INST + 4] = 0.0;
      sc[(size_t)path_idx * MB_INST + 12] = 0.0;
      sc[(size_t)path_idx * MB_INST + 13] = 4.0;
      int seg_idx = idx++;
      double *sd = sc + (size_t)seg_idx * MB_INST;
      sd[5] = 12.0;
      sd[0] = 0.0; sd[1] = 0.0; sd[2] = 1.0; sd[3] = 0.0;
      sd[8] = 1.0; sd[9] = 0.0; sd[10] = 1.0; sd[11] = 1.0;
      sd[12] = 1.0; sd[13] = 1.0; sd[14] = 0.0; sd[15] = 1.0;
      sd[16] = 0.0; sd[17] = 1.0; sd[18] = 0.0; sd[19] = 0.0;
      CHECK(idx == TOTAL);

      // Full baseline draw into off_target (128x128 @ 1x)
      glass_forget();
      off_ok = 0;
      dirty_told = dirty_whole = dirty_n = 0;
      CHECK(submit(sc, TOTAL, 0.10, 0.15, 0.20) == 1);
      int full_submitted = encode_inst_submitted;
      CHECK(full_submitted >= N_GRID);
      CHECK(encode_lens_drawn == 1);
      CHECK(encode_pre_hits_used == 0);

      // Mutate bottom-left path color only; mark 2 disjoint dirty rects:
      // rect 0 touches left edge of warm glass (8, 8, 16, 24), rect 1 covers path (12, 84, 32, 32).
      // Right-side rects & bottom-right kind==8 lens are untouched and outside both rects.
      sc[(size_t)path_idx * MB_INST + 8] = 0.20;
      sc[(size_t)path_idx * MB_INST + 9] = 0.90;
      sc[(size_t)path_idx * MB_INST + 10] = 0.45;
      int segs_before = segs_upload_calls;
      mb_host_render_dirty(8.0, 8.0, 16.0, 24.0);
      mb_host_render_dirty(12.0, 84.0, 32.0, 32.0);
      CHECK(submit(sc, TOTAL, 0.10, 0.15, 0.20) == 1);
      int partial_submitted = encode_inst_submitted;
      int segs_delta = segs_upload_calls - segs_before;
      int lens_after_cull = encode_lens_drawn;
      uint8_t *px_partial = read_offscreen_bgra(W, H);

      // Whole-frame reference draw of the mutated scene
      glass_forget();
      off_ok = 0;
      dirty_told = dirty_whole = dirty_n = 0;
      CHECK(submit(sc, TOTAL, 0.10, 0.15, 0.20) == 1);
      uint8_t *px_ref = read_offscreen_bgra(W, H);

      CHECK(px_partial != NULL && px_ref != NULL);
      int diff_bytes = 0;
      if (px_partial && px_ref) {
        for (size_t i = 0; i < (size_t)W * (size_t)H * 4u; i++) {
          if (px_partial[i] != px_ref[i]) diff_bytes++;
        }
      }
      printf("win_gpu: perf-59 partial full_sub=%d part_sub=%d lens_drawn=%d segs_delta=%d diff_bytes=%d\n",
             full_submitted, partial_submitted, lens_after_cull, segs_delta, diff_bytes);
      CHECK(segs_delta == 1);
      CHECK(lens_after_cull == 0);
      // Without culling, 2 dirty rects submit 2 * full_submitted (~368); culling cuts it well below 1 * full_submitted.
      CHECK(partial_submitted < full_submitted);
      CHECK(diff_bytes == 0);
      free(px_partial);

      // Two disjoint dirty rects both overlapping the same warm glass panel:
      // rect 0 populates pre_hits[0] on slot_same hit, rect 1 reuses pre_hits[0] (encode_pre_hits_used == 1), 0 diff.
      mb_host_render_dirty(8.0, 8.0, 16.0, 24.0);
      mb_host_render_dirty(72.0, 8.0, 16.0, 24.0);
      segs_before = segs_upload_calls;
      CHECK(submit(sc, TOTAL, 0.10, 0.15, 0.20) == 1);
      int two_rect_pre = encode_pre_hits_used;
      int two_rect_segs = segs_upload_calls - segs_before;
      uint8_t *px_two = read_offscreen_bgra(W, H);
      int diff_two = 0;
      if (px_two && px_ref) {
        for (size_t i = 0; i < (size_t)W * (size_t)H * 4u; i++) {
          if (px_two[i] != px_ref[i]) diff_two++;
        }
      }
      printf("win_gpu: perf-59 multi_glass pre_hits=%d segs_delta=%d diff_two=%d\n",
             two_rect_pre, two_rect_segs, diff_two);
      CHECK(two_rect_segs == 1);
      CHECK(two_rect_pre == 1);
      CHECK(diff_two == 0);
      free(px_two);
      free(px_ref);

      // Stale-gen WinPreHit entry is ignored and overwritten in place (never shadows fresh slot).
      int warm_slot = -1;
      for (int s = 0; s < MB_GLASS_SLOTS; s++) {
        if (gslots[s].valid && gslots[s].bt.srv) {
          warm_slot = s;
          break;
        }
      }
      CHECK(warm_slot >= 0);
      if (warm_slot >= 0) {
        Grab gm;
        CHECK(grab_of_with_donors(&gm, last_inst, glass_idx, glass_idx + 1, TOTAL, W, H, NULL) == 1);
        WinPreHit ph[16];
        int ph_n = 1;
        ph[0].tid = -590;
        ph[0].start = glass_idx;
        ph[0].slot = warm_slot;
        ph[0].gen = gslots[warm_slot].gen - 1u;  // stale gen!
        ph[0].grab = gm;
        int switched = 0;
        cut_on = 0;
        encode_pre_hits_used = 0;
        CHECK(capture(rtv, W, H, last_inst, glass_idx, glass_idx + 1, TOTAL, TOTAL - 1, last_bg, gslots_clock,
                      &switched, NULL, ph, &ph_n) == 1);
        CHECK(encode_pre_hits_used == 0);
        CHECK(ph_n == 1);
        CHECK(ph[0].gen == gslots[ph[0].slot].gen);
        // Subsequent call with the refreshed in-place entry hits pre_hits!
        CHECK(capture(rtv, W, H, last_inst, glass_idx, glass_idx + 1, TOTAL, TOTAL - 1, last_bg, gslots_clock,
                      &switched, NULL, ph, &ph_n) == 1);
        CHECK(encode_pre_hits_used == 1);
        glass_forget();
      }
      free(sc);
    }
    vw = saved_vw;
    vh = saved_vh;
    vscale = saved_vscale;
    fb_w = saved_fb_w;
    fb_h = saved_fb_h;
  }

  // (b) compute_donor_plan() occlusion cache: shared box deduplicates scans, and different cur_glass_start never aliases.
  {
    auto pack_bare = [](float hx, float hy) -> float { return -(floorf(hx) * 4096.0f + floorf(hy)); };
    const int N_GLYPHS = 64;
    const int N_TOTAL = 3 + N_GLYPHS;
    float *f = (float *)calloc((size_t)(N_TOTAL + 8) * MB_INST, sizeof(float));
    CHECK(f != NULL);
    if (f) {
      auto set_rect = [](float *p, float x, float y, float w, float h, float kind, float tid) {
        memset(p, 0, MB_INST * sizeof(float));
        p[0] = x; p[1] = y; p[2] = w; p[3] = h; p[5] = kind;
        p[11] = 1.0f; p[16] = -1e9f; p[17] = -1e9f; p[18] = 1e9f; p[19] = 1e9f; p[20] = tid;
      };
      // 0: bg, 1: donor kind 5 (-595), 2: pill kind 6 (-596), 3..66: 64 bare adaptive glyphs sharing box (120, 24, 30, 10)
      set_rect(f, 0, 0, 200, 160, 0, 0);
      set_rect(f + MB_INST, 0, 0, 200, 56, 5, -595.0f);
      f[MB_INST + 6] = 1.0f; f[MB_INST + 7] = 6.0f; f[MB_INST + 11] = 0.0f; f[MB_INST + 15] = 1.0f;
      f[MB_INST + 22] = -1.0f; f[MB_INST + 54] = 56.0f; f[MB_INST + 55] = 24.0f;
      set_rect(f + 2 * MB_INST, 8, 12, 24, 24, 6, -596.0f);
      f[2 * MB_INST + 4] = 12.0f; f[2 * MB_INST + 6] = 1.0f; f[2 * MB_INST + 7] = 1.4f;
      f[2 * MB_INST + 11] = 0.4f; f[2 * MB_INST + 14] = -1.0f; f[2 * MB_INST + 15] = 1.0f;
      f[2 * MB_INST + 21] = 4.0f; f[2 * MB_INST + 23] = 2.0f;
      for (int g = 0; g < N_GLYPHS; g++) {
        float *gp = f + (size_t)(3 + g) * MB_INST;
        set_rect(gp, 92.0f + (float)(g % 32) * 1.5f, 16.0f + (float)(g / 32) * 8.0f, 6.0f, 8.0f, 7.0f, 0.0f);
        gp[21] = 120.0f; gp[22] = 24.0f; gp[23] = pack_bare(30.0f, 10.0f);
      }
      compute_donor_plan(f, N_TOTAL, 200.0f, 160.0f, 2.0f);
      CHECK(donor_delegated_count == N_GLYPHS);
      CHECK(donor_occ_scans == 1);
      for (int g = 0; g < N_GLYPHS; g++) CHECK(donor_of_buf[3 + g] == -595);

      // Insert an opaque occluder between donor (idx 1) and pill (idx 3) overlapping box B only.
      memmove(f + 3 * MB_INST, f + 2 * MB_INST, (size_t)(1 + N_GLYPHS) * MB_INST * sizeof(float));
      set_rect(f + 2 * MB_INST, 150.0f, 16.0f, 16.0f, 16.0f, 0.0f, 0.0f);
      for (int g = 0; g < N_GLYPHS; g++) {
        float *gp = f + (size_t)(4 + g) * MB_INST;
        gp[21] = (g < 32) ? 80.0f : 158.0f;
        gp[22] = 24.0f;
        gp[23] = pack_bare(12.0f, 8.0f);
      }
      compute_donor_plan(f, N_TOTAL + 1, 200.0f, 160.0f, 2.0f);
      CHECK(donor_delegated_count == 32);
      CHECK(donor_occ_scans == 2);
      for (int g = 0; g < 32; g++) CHECK(donor_of_buf[4 + g] == -595);
      for (int g = 32; g < N_GLYPHS; g++) CHECK(donor_of_buf[4 + g] == 0);

      // Same occ_sr box under two different cur_glass_start pills with an occluder between pill 1 and pill 2:
      // pill 1's glyphs are unoccluded (delegated), pill 2's glyphs are occluded (not delegated), donor_occ_scans == 2.
      memset(f, 0, (size_t)(N_TOTAL + 8) * MB_INST * sizeof(float));
      set_rect(f, 0, 0, 200, 160, 0, 0);
      set_rect(f + MB_INST, 0, 0, 200, 56, 5, -595.0f);
      f[MB_INST + 6] = 1.0f; f[MB_INST + 7] = 6.0f; f[MB_INST + 11] = 0.0f; f[MB_INST + 15] = 1.0f;
      f[MB_INST + 22] = -1.0f; f[MB_INST + 54] = 56.0f; f[MB_INST + 55] = 24.0f;
      // Pill 1 at idx 2 (-596) + 4 glyphs at idx 3..6 on box (120, 24, 16, 8)
      set_rect(f + 2 * MB_INST, 8, 12, 24, 24, 6, -596.0f);
      f[2 * MB_INST + 4] = 12.0f; f[2 * MB_INST + 6] = 1.0f; f[2 * MB_INST + 7] = 1.4f;
      f[2 * MB_INST + 11] = 0.4f; f[2 * MB_INST + 14] = -1.0f; f[2 * MB_INST + 15] = 1.0f;
      f[2 * MB_INST + 21] = 4.0f; f[2 * MB_INST + 23] = 2.0f;
      for (int g = 0; g < 4; g++) {
        float *gp = f + (size_t)(3 + g) * MB_INST;
        set_rect(gp, 110.0f + (float)g * 4.0f, 18.0f, 6.0f, 10.0f, 7.0f, 0.0f);
        gp[21] = 120.0f; gp[22] = 24.0f; gp[23] = pack_bare(16.0f, 8.0f);
      }
      // Opaque occluder at idx 7 overlapping box (120, 24, 16, 8)
      set_rect(f + 7 * MB_INST, 112.0f, 18.0f, 16.0f, 12.0f, 0.0f, 0.0f);
      // Pill 2 at idx 8 (-597, same blur/refract/rim -> identical occ_sr!) + 4 glyphs at idx 9..12 on the same box
      memcpy(f + 8 * MB_INST, f + 2 * MB_INST, MB_INST * sizeof(float));
      f[8 * MB_INST + 20] = -597.0f;
      for (int g = 0; g < 4; g++) {
        float *gp = f + (size_t)(9 + g) * MB_INST;
        set_rect(gp, 110.0f + (float)g * 4.0f, 18.0f, 6.0f, 10.0f, 7.0f, 0.0f);
        gp[21] = 120.0f; gp[22] = 24.0f; gp[23] = pack_bare(16.0f, 8.0f);
      }
      compute_donor_plan(f, 13, 200.0f, 160.0f, 2.0f);
      CHECK(donor_delegated_count == 4);
      CHECK(donor_occ_scans == 2);
      for (int g = 0; g < 4; g++) CHECK(donor_of_buf[3 + g] == -595);
      for (int g = 0; g < 4; g++) CHECK(donor_of_buf[9 + g] == 0);
      free(f);
    }
  }
  printf("win_gpu: perf-59 ok\n");
}

int main(void) {
  // 1. Initial values before any frame.
  CHECK(mb_host_gpu_ms() == -1.0);
  CHECK(mb_host_frames_dropped() == 0);

  // 2. Pure dropped-frame boundary logic, frame_late continuity, & frame_pace grid logic.
  test_dropped_step_logic();
  test_frame_late_logic();
  test_frame_pace_logic();

  // 3. D3D11 timestamp query ring on WARP offscreen device.
  mb_render_init_offscreen(128.0, 128.0, 1.0);
  CHECK(dev != NULL && ctx != NULL && rtv != NULL);
  if (!dev || !ctx || !rtv) return 1;

  static double inst[32 * MB_INST];
  fill_rect_instances(inst, 32);

  for (int i = 0; i < 8; i++) {
    CHECK(submit(inst, 32, 1.0, 1.0, 1.0) == 1);
    ctx->Flush();
  }
  // Synchronize with WARP's execution queue via a D3D11 event query (first-draw shader JIT on
  // loaded CI VMs can exceed a short Sleep(1) loop), then verify production's non-blocking
  // gpu_q_poll() (D3D11_ASYNC_GETDATA_DONOTFLUSH) drains every in-flight timestamp slot.
  {
    D3D11_QUERY_DESC eq = {};
    eq.Query = D3D11_QUERY_EVENT;
    ID3D11Query *fence = NULL;
    CHECK(SUCCEEDED(dev->CreateQuery(&eq, &fence)) && fence != NULL);
    if (fence) {
      ctx->End(fence);
      ctx->Flush();
      BOOL done = FALSE;
      HRESULT hr = S_FALSE;
      ULONGLONG deadline = GetTickCount64() + 10000;
      while (((hr = ctx->GetData(fence, &done, sizeof done, 0)) == S_FALSE || (hr == S_OK && !done)) &&
             GetTickCount64() < deadline) {
        Sleep(1);
      }
      CHECK(hr == S_OK && done != FALSE);
      fence->Release();
    }
  }
  gpu_q_poll();
  if (gpu_q_ok) {
    int any_in_flight = 0;
    for (int i = 0; i < MB_GPU_Q_SLOTS; i++) any_in_flight |= gpu_q[i].in_flight;
    CHECK(any_in_flight == 0);
    // On WARP, timestamp queries normally return >= 0.0 (unless Disjoint=TRUE, in which case -1.0 without crash).
    double gms = mb_host_gpu_ms();
    CHECK(gms >= 0.0 || gms == -1.0);
    printf("win_gpu: warp gpu_ms=%.3f\n", gms);
  } else {
    CHECK(mb_host_gpu_ms() == -1.0);
    printf("win_gpu: timestamp queries unsupported on adapter (graceful fallback)\n");
  }

  // 4. gpu_q_free() cleans up and next submit() re-initializes cleanly.
  gpu_q_free();
  for (int i = 0; i < MB_GPU_Q_SLOTS; i++) {
    CHECK(gpu_q[i].disjoint == NULL && gpu_q[i].ts_begin == NULL && gpu_q[i].ts_end == NULL);
  }
  CHECK(submit(inst, 16, 1.0, 1.0, 1.0) == 1);
  ctx->Flush();
  gpu_q_free();

  // 5. P0 Regular Liquid Glass optics 5+2 numerical vector readback on D3D11 WARP production shader.
  test_p0_liquid_glass_vectors();

  // 6. Commit 2 V8/V9 2D Multi-Pixel ROI gates on D3D11 WARP production shader.
  test_v8_v9_droplet_roi_gates();

  // 7. Perf-51 R2 donor delegation, 33rd cold capture pin, lens counterexample & provoking-vertex verification.
  test_perf51_donor_and_provoking_vertex();

  // 8. The reflection of what is outside liquid glass (glass_reflect_cases.h) on D3D11 WARP.
  glass_reflect_cases();

  // 9. Liquid glass over native-view holes (kind == 9) produces translucent premultiplied output.
  test_liquid_over_hole();

  // 10. Perf-59: encode_rects() CPU culling/lens/pre_hits/segs_upload & WARP parity, donor occlusion cache.
  test_perf59_cull_and_donor();

  if (failed) return 1;
  printf("win_gpu: ok\n");
  return 0;
}
