// src/host/win_render.cpp atlas upload coalescing tests on Windows:
//   cl.exe -nologo -EHsc -W3 -WX -D_CRT_SECURE_NO_WARNINGS -Isrc/host scripts/win_atlas_test.cpp \
//     -Foout/atlas/ -Feout/atlas/win_atlas_test.exe \
//     -link d3d11.lib d3dcompiler.lib dcomp.lib dwmapi.lib gdi32.lib user32.lib windowscodecs.lib ole32.lib
//   out/atlas/win_atlas_test.exe
// Verifies that mb_atlas_upload buffers uploads and atlas_flush coalesces adjacent horizontal shelf runs (same y,
// x == right + 1 within the same 512px plot) into a single D3D11 UpdateSubresource call before drawing, while keeping
// non-adjacent runs and plot boundaries separate and preserving exact RGBA pixels and zeroed gutters.
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
static size_t test_out_bytes_len = 0;
static size_t Moonbit_array_length(moonbit_bytes_t) { return test_out_bytes_len; }

struct AtlasCall {
  UINT left, top, right, bottom;
  UINT pitch;
  uint8_t *data;
  size_t bytes;
};
static AtlasCall atlas_calls[64];
static int atlas_calls_n = 0;

static void reset_atlas_calls(void) {
  for (int i = 0; i < atlas_calls_n; i++) free(atlas_calls[i].data);
  atlas_calls_n = 0;
}

static void test_atlas_update(ID3D11DeviceContext *c, ID3D11Resource *tex, const D3D11_BOX *box, const void *data,
                              UINT pitch) {
  if (atlas_calls_n < 64) {
    AtlasCall *ac = &atlas_calls[atlas_calls_n++];
    ac->left = box->left;
    ac->top = box->top;
    ac->right = box->right;
    ac->bottom = box->bottom;
    ac->pitch = pitch;
    UINT h = box->bottom - box->top;
    ac->bytes = (size_t)pitch * (size_t)h;
    ac->data = (uint8_t *)malloc(ac->bytes);
    if (ac->data) memcpy(ac->data, data, ac->bytes);
  }
  c->UpdateSubresource(tex, 0, box, data, pitch, 0);
}
#define MB_WIN_ATLAS_UPDATE(c, tex, box, data, pitch) test_atlas_update((c), (tex), (box), (data), (pitch))

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

static void fill_solid(uint8_t *buf, int w, int h, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
  for (int i = 0; i < w * h; i++) {
    buf[i * 4 + 0] = r;
    buf[i * 4 + 1] = g;
    buf[i * 4 + 2] = b;
    buf[i * 4 + 3] = a;
  }
}

static void fill_one_rect(double *inst) {
  memset(inst, 0, MB_INST * sizeof(double));
  inst[0] = 0.0;
  inst[1] = 0.0;
  inst[2] = 16.0;
  inst[3] = 16.0;
  inst[8] = 0.5;
  inst[9] = 0.5;
  inst[10] = 0.5;
  inst[11] = 1.0;
  inst[16] = -1e9;
  inst[17] = -1e9;
  inst[18] = 1e9;
  inst[19] = 1e9;
}

int main(void) {
  mb_render_init_offscreen(64.0, 64.0, 1.0);
  CHECK(dev != NULL && ctx != NULL && rtv != NULL && atlas != NULL);
  if (!dev || !ctx || !rtv || !atlas) return 1;

  static double inst[MB_INST];
  fill_one_rect(inst);

  // 1. Three adjacent glyphs on the same shelf (y = 4, 1px gutter) coalesce into 1 UpdateSubresource on submit().
  uint8_t g1[10 * 12 * 4], g2[8 * 16 * 4], g3[6 * 10 * 4];
  fill_solid(g1, 10, 12, 10, 20, 30, 40);
  fill_solid(g2, 8, 16, 50, 60, 70, 80);
  fill_solid(g3, 6, 10, 90, 100, 110, 120);

  reset_atlas_calls();
  mb_atlas_upload(0, 4, 10, 12, g1);
  mb_atlas_upload(11, 4, 8, 16, g2);
  mb_atlas_upload(20, 4, 6, 10, g3);
  CHECK(atlas_calls_n == 0);  // buffered until draw

  CHECK(submit(inst, 1, 1.0, 1.0, 1.0) == 1);
  CHECK(atlas_calls_n == 1);
  if (atlas_calls_n == 1) {
    AtlasCall *ac = &atlas_calls[0];
    CHECK(ac->left == 0 && ac->top == 4 && ac->right == 26 && ac->bottom == 20);
    CHECK(ac->pitch == 26 * 4);
    for (int y = 0; y < 16; y++) {
      for (int x = 0; x < 26; x++) {
        const uint8_t *p = ac->data + ((size_t)y * 26 + (size_t)x) * 4;
        if (x < 10 && y < 12) {
          CHECK(p[0] == 10 && p[1] == 20 && p[2] == 30 && p[3] == 40);
        } else if (x >= 11 && x < 19) {
          CHECK(p[0] == 50 && p[1] == 60 && p[2] == 70 && p[3] == 80);
        } else if (x >= 20 && x < 26 && y < 10) {
          CHECK(p[0] == 90 && p[1] == 100 && p[2] == 110 && p[3] == 120);
        } else {
          CHECK(p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 0);
        }
      }
    }
  }

  // 2. Non-adjacent uploads: different y, gap > 1, and crossing 512px plot boundary must NOT coalesce.
  uint8_t a[11 * 8 * 4], b[8 * 8 * 4], c[4 * 4 * 4], d[4 * 4 * 4];
  fill_solid(a, 11, 8, 1, 2, 3, 4);
  fill_solid(b, 8, 8, 5, 6, 7, 8);
  fill_solid(c, 4, 4, 9, 10, 11, 12);
  fill_solid(d, 4, 4, 13, 14, 15, 16);

  reset_atlas_calls();
  // Plot 0 ends at x = 500 + 11 = 511; Plot 1 starts at x = 512 (= right + 1, but different 512px plot!).
  mb_atlas_upload(500, 0, 11, 8, a);
  mb_atlas_upload(512, 0, 8, 8, b);
  // Different y:
  mb_atlas_upload(512, 20, 4, 4, c);
  // Gap > 1 on same y (512 + 4 = 516, next at 520):
  mb_atlas_upload(520, 20, 4, 4, d);
  CHECK(atlas_calls_n == 0);

  CHECK(submit(inst, 1, 1.0, 1.0, 1.0) == 1);
  CHECK(atlas_calls_n == 4);
  if (atlas_calls_n == 4) {
    CHECK(atlas_calls[0].left == 500 && atlas_calls[0].right == 511 && atlas_calls[0].top == 0 && atlas_calls[0].bottom == 8);
    CHECK(atlas_calls[1].left == 512 && atlas_calls[1].right == 520 && atlas_calls[1].top == 0 && atlas_calls[1].bottom == 8);
    CHECK(atlas_calls[2].left == 512 && atlas_calls[2].right == 516 && atlas_calls[2].top == 20 && atlas_calls[2].bottom == 24);
    CHECK(atlas_calls[3].left == 520 && atlas_calls[3].right == 524 && atlas_calls[3].top == 20 && atlas_calls[3].bottom == 24);
  }

  // 3. mb_render_pixels_of flushes pending atlas uploads before drawing.
  uint8_t out_px[16 * 16 * 4];
  test_out_bytes_len = sizeof(out_px);
  reset_atlas_calls();
  mb_atlas_upload(0, 64, 4, 4, c);
  mb_atlas_upload(5, 64, 4, 4, d);
  CHECK(atlas_calls_n == 0);
  CHECK(mb_render_pixels_of(inst, 1, 1.0, 1.0, 1.0, 1.0, 16, 16, out_px) == 1);
  CHECK(atlas_calls_n == 1);
  if (atlas_calls_n == 1) {
    CHECK(atlas_calls[0].left == 0 && atlas_calls[0].right == 9 && atlas_calls[0].top == 64 && atlas_calls[0].bottom == 68);
  }

  reset_atlas_calls();
  if (failed) return 1;
  printf("win_atlas: ok\n");
  return 0;
}
