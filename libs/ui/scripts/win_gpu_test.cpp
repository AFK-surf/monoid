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
void *mb_stream_srv(int) { return NULL; }
void mb_text_set_scale(double) {}
int mb_views_count(void) { return 0; }
void mb_views_draw_under(uint8_t *, int, int, double) {}
double mb_app_scale(void) { return 1.0; }
}

#include "win_render.cpp"

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
  // First sample (has_prev = 0): never counts drops.
  CHECK(win_count_dropped_step(0, 0, 0, 0, 10, 20, 100000, freq, p60, 1) == 0);
  // Continuous 60Hz (dt = 16.67ms < 41.67ms), no drops (d_sync == d_present == 1).
  CHECK(win_count_dropped_step(10, 100, 100000, 1, 11, 101, 266700, freq, p60, 1) == 0);
  // Continuous animation (dt = 33.3ms < 41.67ms), 2 sync refreshes missed (d_sync=3, d_present=1).
  CHECK(win_count_dropped_step(10, 100, 100000, 1, 11, 103, 433000, freq, p60, 1) == 2);
  // Idle pause (dt = 50ms >= 2.5 * 16.67ms): ignored even if d_sync > d_present.
  CHECK(win_count_dropped_step(10, 100, 100000, 1, 11, 104, 600000, freq, p60, 1) == 0);
  // Huge spike within continuous window: clamped to MB_WIN_DROPPED_CLAMP (10).
  CHECK(win_count_dropped_step(10, 100, 100000, 1, 11, 150, 300000, freq, p60, 1) == MB_WIN_DROPPED_CLAMP);
  // Non-monotonic QPC or PresentCount: 0.
  CHECK(win_count_dropped_step(10, 100, 200000, 1, 11, 103, 100000, freq, p60, 1) == 0);
  CHECK(win_count_dropped_step(10, 100, 100000, 1, 10, 103, 200000, freq, p60, 1) == 0);
  // 120Hz continuous (period = 8.33ms, 2.5x = 20.83ms): dt = 16.67ms counts 1 drop, dt = 22ms ignored.
  const double p120 = 1000.0 / 120.0;
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 12, 266700, freq, p120, 1) == 1);
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 13, 320000, freq, p120, 1) == 0);

  // 240Hz paced to 120fps (beats = 2, period = 8.33ms per frame, 2.5x = 20.83ms): each present expects 2 syncs.
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 12, 183300, freq, p120, 2) == 0);   // normal frame
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 13, 225000, freq, p120, 2) == 0);   // one-beat phase jitter
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 14, 266700, freq, p120, 2) == 1);   // one 120fps frame dropped
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 16, 300000, freq, p120, 2) == 2);   // two dropped
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 3, 16, 300000, freq, p120, 2) == 1);   // two presents, one dropped
  // 360Hz paced to 120fps (beats = 3).
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 13, 183300, freq, p120, 3) == 0);   // normal frame
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 16, 266700, freq, p120, 3) == 1);   // one dropped
  // Waking from a 500ms idle: the samples' own sync times are 500ms apart, so the long sync gap is not a drop.
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 130, 5100000, freq, p120, 2) == 0);
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 130, 5100000, freq, p60, 1) == 0);
  // A sample without a sync time, or no beats: 0.
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 14, 0, freq, p120, 2) == 0);
  CHECK(win_count_dropped_step(1, 10, 0, 1, 2, 14, 166700, freq, p120, 2) == 0);
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 14, 266700, freq, p120, 0) == 0);
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 14, 266700, freq, p120, -1) == 0);
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

static int read_ad_bright_t(double *out_t) {
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
      CHECK(rgb[0] >= 26 && rgb[0] <= 34 && rgb[1] >= 26 && rgb[1] <= 34 && rgb[2] >= 26 && rgb[2] <= 34);
    } else if (i == 1) {
      CHECK(rgb[0] >= 41 && rgb[0] <= 51 && rgb[1] >= 42 && rgb[1] <= 52 && rgb[2] >= 45 && rgb[2] <= 55);
    } else if (i == 2) {
      CHECK(rgb[0] >= 85 && rgb[0] <= 101 && rgb[1] >= 85 && rgb[1] <= 101 && rgb[2] >= 85 && rgb[2] <= 101);
    } else if (i == 3) {
      double mx = (double)(rgb[0] > rgb[1] ? (rgb[0] > rgb[2] ? rgb[0] : rgb[2]) : (rgb[1] > rgb[2] ? rgb[1] : rgb[2]));
      double mn = (double)(rgb[0] < rgb[1] ? (rgb[0] < rgb[2] ? rgb[0] : rgb[2]) : (rgb[1] < rgb[2] ? rgb[1] : rgb[2]));
      double sat = mx > 0.0 ? (mx - mn) / mx : 0.0;
      CHECK(rgb[0] >= 27 && rgb[0] <= 51 && rgb[1] >= 142 && rgb[1] <= 166 && rgb[2] >= 243 && sat >= 0.80);
    } else if (i == 4) {
      CHECK(rgb[0] <= 8 && rgb[1] >= 247 && rgb[2] >= 56 && rgb[2] <= 72);
    } else if (i == 5) {
      CHECK(rgb[0] >= (uint8_t)(0.72 * 255.0 + 0.5) && rgb[1] >= 200 && rgb[2] >= 240);
    } else if (i == 6) {
      CHECK(rgb[0] >= 249 && rgb[1] >= 248 && rgb[2] >= 249);
    }
    free(px);
  }

  // Stateful adaptive transition test via submit() (verifies !is_new fix when serial == 0 and deterministic tau=70ms exponential convergence):
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
    uint8_t rgb0[3] = {0, 0, 0};
    CHECK(read_ad_bright_t(&frame0_t) == 1);
    CHECK(read_offscreen_pixel_rgb(64, 64, rgb0) == 1);
    CHECK(frame0_t >= 0.98);
    CHECK(rgb0[0] >= 85 && rgb0[0] <= 101 && rgb0[1] >= 85 && rgb0[1] <= 101 && rgb0[2] >= 85 && rgb0[2] <= 101);

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
    printf("win_gpu: stateful_ad frame0_t=%.4f mid_frame3_t=%.4f final_t=%.4f final_rgb=(%u,%u,%u)\n",
           frame0_t, mid_frame3_t, final_t, final_rgb[0], final_rgb[1], final_rgb[2]);
    CHECK(mid_frame3_t > 0.25 && mid_frame3_t < 0.75);
    CHECK(final_t <= 0.02);
    CHECK(final_rgb[0] >= 26 && final_rgb[0] <= 34 && final_rgb[1] >= 26 && final_rgb[1] <= 34 && final_rgb[2] >= 26 && final_rgb[2] <= 34);
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
    sl[3 * MB_INST + 12] = 1.0; sl[3 * MB_INST + 13] = 8.0; sl[3 * MB_INST + 15] = 1.0;
    sl[3 * MB_INST + 21] = 3.0;
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
        if (is_light ? (cy < ref_y - 80.0) : (cy > ref_y + 25.0)) cnt++;
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
    CHECK(max_bh >= 10.0 && max_bh <= 12.0);
    CHECK(peak_dx >= 0.67 && peak_dx <= 1.33);
    CHECK(h_55 >= 5.6 && h_55 <= 6.4);
    CHECK(max_gh >= 10.0 && max_gh <= 12.0);
    CHECK(grey_peak_dx >= 0.67 && grey_peak_dx <= 1.33);
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
    st[41 * MB_INST + 12] = 1.0; st[41 * MB_INST + 13] = 8.0; st[41 * MB_INST + 15] = 1.0; st[41 * MB_INST + 21] = 3.0;
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

  // V9c: Light Segmented Prism @ 3x
  {
    double sg[2 * MB_INST];
    fill_p0_rect(sg, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 1.0, 0);
    fill_p0_rect(sg + MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, 0.0, -56.0);
    sg[MB_INST + 4] = 22.5; sg[MB_INST + 6] = 1.0; sg[MB_INST + 7] = -48.0;
    sg[MB_INST + 12] = 1.0; sg[MB_INST + 13] = 9.0; sg[MB_INST + 15] = 1.0;
    sg[MB_INST + 21] = 9.0; sg[MB_INST + 22] = 0.04;
    uint8_t *px = render_rgba_pixels_of(sg, 2, 1.0, 1.0, 1.0, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (px) {
      uint8_t *bot = W_PX(px, AW3, 80 * 3, (int)(61.6 * 3));
      uint8_t *lft = W_PX(px, AW3, (int)(25.9 * 3), 40 * 3);
      printf("win_gpu: v9_seg_light bot=(%u,%u,%u) B-R=%d lft=(%u,%u,%u) R-B=%d\n",
             bot[0], bot[1], bot[2], (int)bot[2] - (int)bot[0], lft[0], lft[1], lft[2], (int)lft[0] - (int)lft[2]);
      CHECK((int)bot[2] - (int)bot[0] >= 10);
      CHECK((int)lft[0] - (int)lft[2] >= 20);
      free(px);
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
  #undef W_PX
}

int main(void) {
  // 1. Initial values before any frame.
  CHECK(mb_host_gpu_ms() == -1.0);
  CHECK(mb_host_frames_dropped() == 0);

  // 2. Pure dropped-frame boundary logic.
  test_dropped_step_logic();

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
  // Poll until WARP finishes queued work (bounded spin with Sleep(1) only in test harness after Flush).
  for (int tries = 0; tries < 50; tries++) {
    gpu_q_poll();
    int any_in_flight = 0;
    for (int i = 0; i < MB_GPU_Q_SLOTS; i++) any_in_flight |= gpu_q[i].in_flight;
    if (!any_in_flight) break;
    Sleep(1);
  }
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

  if (failed) return 1;
  printf("win_gpu: ok\n");
  return 0;
}
