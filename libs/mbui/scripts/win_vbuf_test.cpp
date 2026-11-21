// src/host/win_render.cpp's vertex-buffer and allocation-failure tests on Windows:
//   cl.exe -nologo -EHsc -W3 -WX -D_CRT_SECURE_NO_WARNINGS -Isrc/host scripts/win_vbuf_test.cpp \
//     -Foout/vbuf/ -Feout/vbuf/win_vbuf_test.exe \
//     -link d3d11.lib d3dcompiler.lib dcomp.lib dwmapi.lib gdi32.lib user32.lib windowscodecs.lib ole32.lib
//   out/vbuf/win_vbuf_test.exe
// Verifies that D3D11 dynamic vertex buffer growth handles UINT_MAX overflow and CreateBuffer failures without
// leaving a dangling/NULL `vbuf` dereferenced by `ctx->Map` (0xC0000005), and recovers cleanly on the next frame.
#define MB_NO_MOONBIT_H 1
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef const wchar_t *moonbit_string_t;
typedef uint8_t *moonbit_bytes_t;
static size_t test_out_bytes_len = 0;
static size_t Moonbit_array_length(moonbit_bytes_t) { return test_out_bytes_len; }

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
    p[0] = (double)(i * 4);
    p[1] = (double)(i * 4);
    p[2] = 16.0;
    p[3] = 16.0;
    p[8] = 0.2;
    p[9] = 0.4;
    p[10] = 0.8;
    p[11] = 1.0;
    p[16] = -1e9;
    p[17] = -1e9;
    p[18] = 1e9;
    p[19] = 1e9;
  }
}

int main(void) {
  mb_render_init_offscreen(128.0, 128.0, 1.0);
  CHECK(dev != NULL && ctx != NULL && rtv != NULL);
  if (!dev || !ctx || !rtv) return 1;

  double inst[16 * MB_INST];
  float finst[16 * MB_INST];
  fill_rect_instances(inst, 16);
  for (int i = 0; i < 16 * MB_INST; i++) finst[i] = (float)inst[i];

  // 1. Normal frame succeeds and allocates vbuf.
  CHECK(submit(inst, 16, 1.0, 1.0, 1.0) == 1);
  CHECK(vbuf != NULL && vbuf_cap >= 17u * MB_INST * sizeof(float));

  // 2. Overflow count (> UINT_MAX bytes) fails cleanly without crashing.
  uint8_t px[16 * 16 * 4];
  test_out_bytes_len = sizeof(px);
  CHECK(submit(inst, 20000000, 1.0, 1.0, 1.0) == 0);
  CHECK(fill_vbuf(finst, 20000000) == 0);
  CHECK(mb_render_pixels_of(inst, 20000000, 1.0, 1.0, 1.0, 1.0, 16, 16, px) == 0);

  // 3. Oversized CreateBuffer request (under UINT_MAX, over D3D11 resource limit) returns 0 and clears vbuf.
  CHECK(ensure_vbuf(0xF0000000u) == 0);
  CHECK(vbuf == NULL && vbuf_cap == 0);

  // 4. fill_vbuf with oversized count also fails cleanly and leaves vbuf NULL.
  CHECK(fill_vbuf(finst, 16000000) == 0);
  CHECK(vbuf == NULL && vbuf_cap == 0);

  // 5. Next normal frame and offscreen pixel read recover cleanly after the failure.
  CHECK(submit(inst, 16, 1.0, 1.0, 1.0) == 1);
  CHECK(vbuf != NULL && vbuf_cap >= 17u * MB_INST * sizeof(float));
  CHECK(mb_render_pixels_of(inst, 16, 1.0, 1.0, 1.0, 1.0, 16, 16, px) == 1);

  if (failed) return 1;
  printf("win_vbuf: ok\n");
  return 0;
}
