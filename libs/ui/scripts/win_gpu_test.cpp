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
static size_t Moonbit_array_length(moonbit_bytes_t) { return 0; }

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
    glass_free();
    CHECK(submit(inst, 2, cases[i].bg[0], cases[i].bg[1], cases[i].bg[2]) == 1);
    ctx->Flush();
    uint8_t rgb[3] = {0, 0, 0};
    CHECK(read_offscreen_pixel_rgb(64, 64, rgb) == 1);
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
  }
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

  if (failed) return 1;
  printf("win_gpu: ok\n");
  return 0;
}
