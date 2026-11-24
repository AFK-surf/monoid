// src/host/win_render.cpp's vertex-buffer and allocation-failure tests on Windows:
//   cl.exe -nologo -EHsc -W3 -WX -D_CRT_SECURE_NO_WARNINGS -Isrc/host scripts/win_vbuf_test.cpp \
//     -Foout/vbuf/ -Feout/vbuf/win_vbuf_test.exe \
//     -link d3d11.lib d3dcompiler.lib dcomp.lib dwmapi.lib gdi32.lib user32.lib windowscodecs.lib ole32.lib
//   out/vbuf/win_vbuf_test.exe
// Verifies that D3D11 dynamic vertex buffer growth handles UINT_MAX overflow and CreateBuffer failures without
// leaving a dangling/NULL `vbuf` dereferenced by `ctx->Map` (0xC0000005), recovers cleanly on the next frame,
// isolates per-window vertex buffers across partial redraws (such as `mb_render_adaptive_step`) and
// `mb_render_pixels_of`, and keeps shared glass caches alive while another open window still renders glass.
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

static int fail_create_buffer_count = 0;
static HRESULT test_create_buffer(ID3D11Device *d, const D3D11_BUFFER_DESC *desc,
                                  const D3D11_SUBRESOURCE_DATA *init, ID3D11Buffer **out) {
  if (fail_create_buffer_count > 0) {
    fail_create_buffer_count--;
    *out = NULL;
    return E_OUTOFMEMORY;
  }
  return d->CreateBuffer(desc, init, out);
}
#define MB_WIN_CREATE_BUFFER(d, desc, init, out) test_create_buffer((d), (desc), (init), (out))

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
    p[0] = (double)(i % 32);
    p[1] = (double)(i / 32);
    p[2] = 8.0;
    p[3] = 8.0;
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

  static double inst[128 * MB_INST];
  static float finst[128 * MB_INST];
  fill_rect_instances(inst, 128);
  for (int i = 0; i < 128 * MB_INST; i++) finst[i] = (float)inst[i];

  // 1. Normal frame succeeds and allocates vbuf.
  CHECK(submit(inst, 16, 1.0, 1.0, 1.0) == 1);
  CHECK(vbuf != NULL && vbuf_cap >= 17u * MB_INST * sizeof(float));

  // 2. Overflow count (> UINT_MAX bytes) fails cleanly without crashing.
  uint8_t px[16 * 16 * 4];
  test_out_bytes_len = sizeof(px);
  CHECK(submit(inst, 20000000, 1.0, 1.0, 1.0) == 0);
  CHECK(fill_vbuf(finst, 20000000) == 0);
  CHECK(mb_render_pixels_of(inst, 20000000, 1.0, 1.0, 1.0, 1.0, 16, 16, px) == 0);

  // 3. When 2x CreateBuffer fails with E_OUTOFMEMORY, ensure_vbuf falls back to exact `room` and succeeds.
  fail_create_buffer_count = 1;
  CHECK(submit(inst, 64, 1.0, 1.0, 1.0) == 1);
  CHECK(fail_create_buffer_count == 0);
  CHECK(vbuf != NULL && vbuf_cap == 65u * MB_INST * sizeof(float));

  // 4. When both 2x and exact-size CreateBuffer fail, submit() returns 0 with vbuf cleared (no Map(NULL) crash).
  fail_create_buffer_count = 2;
  CHECK(submit(inst, 128, 1.0, 1.0, 1.0) == 0);
  CHECK(fail_create_buffer_count == 0);
  CHECK(vbuf == NULL && vbuf_cap == 0);

  // 5. Same for fill_vbuf() when CreateBuffer fails.
  fail_create_buffer_count = 2;
  CHECK(fill_vbuf(finst, 128) == 0);
  CHECK(fail_create_buffer_count == 0);
  CHECK(vbuf == NULL && vbuf_cap == 0);

  // 6. Next normal frame and offscreen pixel read recover cleanly after the failure.
  CHECK(submit(inst, 16, 1.0, 1.0, 1.0) == 1);
  CHECK(vbuf != NULL && vbuf_cap >= 17u * MB_INST * sizeof(float));
  CHECK(mb_render_pixels_of(inst, 16, 1.0, 1.0, 1.0, 1.0, 16, 16, px) == 1);

  // Helper to read a single BGRA pixel from `off_target`.
  auto read_off_bgra = [](int x, int y, uint8_t out[4]) -> int {
    D3D11_TEXTURE2D_DESC td = {};
    off_target->GetDesc(&td);
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Texture2D *st = NULL;
    if (FAILED(dev->CreateTexture2D(&td, NULL, &st)) || !st) return 0;
    ctx->CopyResource(st, off_target);
    D3D11_MAPPED_SUBRESOURCE m;
    int ok = 0;
    if (SUCCEEDED(ctx->Map(st, 0, D3D11_MAP_READ, 0, &m))) {
      const uint8_t *p = (const uint8_t *)m.pData + (size_t)y * m.RowPitch + (size_t)x * 4;
      memcpy(out, p, 4);
      ctx->Unmap(st, 0);
      ok = 1;
    }
    st->Release();
    return ok;
  };

  // 7. Multi-window vertex-buffer isolation: window 1's submit() must not clobber window 0's vbuf or ground slot
  //    used by subsequent partial redraws (mb_render_adaptive_step).
  static double win0_inst[32 * MB_INST];
  memset(win0_inst, 0, sizeof win0_inst);
  for (int i = 0; i < 32; i++) {
    double *p = win0_inst + (size_t)i * MB_INST;
    p[16] = -1e9; p[17] = -1e9; p[18] = 1e9; p[19] = 1e9;
  }
  {
    // Place a bright green quad at slot 24 (well past window 1's instance count).
    double *g = win0_inst + (size_t)24 * MB_INST;
    g[0] = 20.0; g[1] = 20.0; g[2] = 40.0; g[3] = 40.0;
    g[8] = 0.0; g[9] = 1.0; g[10] = 0.0; g[11] = 1.0;
  }
  mb_render_use(0);
  CHECK(submit(win0_inst, 32, 1.0, 0.0, 0.0) == 1);
  ID3D11Buffer *win0_vb = render_wins[0].win_vbuf;
  CHECK(win0_vb != NULL);

  // Set up an offscreen render target on window 1 and submit a small 2-instance blue frame.
  D3D11_TEXTURE2D_DESC td1 = {};
  td1.Width = 128; td1.Height = 128; td1.MipLevels = td1.ArraySize = 1;
  td1.Format = DXGI_FORMAT_B8G8R8A8_UNORM; td1.SampleDesc.Count = 1;
  td1.Usage = D3D11_USAGE_DEFAULT; td1.BindFlags = D3D11_BIND_RENDER_TARGET;
  ID3D11Texture2D *win1_tex = NULL;
  ID3D11RenderTargetView *win1_rtv = NULL;
  CHECK(SUCCEEDED(dev->CreateTexture2D(&td1, NULL, &win1_tex)) && win1_tex != NULL);
  CHECK(SUCCEEDED(dev->CreateRenderTargetView(win1_tex, NULL, &win1_rtv)) && win1_rtv != NULL);
  mb_render_use(1);
  render_win_fresh(rw);
  rtv = win1_rtv;
  fb_w = 128; fb_h = 128; vw = 128.0; vh = 128.0; vscale = 1.0;
  static double win1_inst[2 * MB_INST];
  memset(win1_inst, 0, sizeof win1_inst);
  for (int i = 0; i < 2; i++) {
    double *p = win1_inst + (size_t)i * MB_INST;
    p[0] = 0.0; p[1] = 0.0; p[2] = 128.0; p[3] = 128.0;
    p[8] = 0.0; p[9] = 0.0; p[10] = 1.0; p[11] = 1.0;
    p[16] = -1e9; p[17] = -1e9; p[18] = 1e9; p[19] = 1e9;
  }
  CHECK(submit(win1_inst, 2, 0.0, 0.0, 0.0) == 1);
  CHECK(render_wins[1].win_vbuf != NULL && render_wins[1].win_vbuf != win0_vb);
  CHECK(render_wins[0].win_vbuf == win0_vb);

  // Switch back to window 0, overwrite off_target with blue, then run partial encode() without re-uploading vbuf.
  mb_render_use(0);
  const float blue_clear[4] = {0.0f, 0.0f, 1.0f, 1.0f};
  ctx->ClearRenderTargetView(rtv, blue_clear);
  const D3D11_RECT part = {10, 10, 70, 70};
  encode(rtv, fb_w, fb_h, last_count, last_bg, last_inst, &part);
  uint8_t px_ground[4] = {}, px_green[4] = {}, px_outside[4] = {};
  CHECK(read_off_bgra(12, 12, px_ground) == 1);
  CHECK(read_off_bgra(40, 40, px_green) == 1);
  CHECK(read_off_bgra(2, 2, px_outside) == 1);
  CHECK(px_ground[2] > 250 && px_ground[1] < 5 && px_ground[0] < 5);
  CHECK(px_green[1] > 250 && px_green[2] < 5 && px_green[0] < 5);
  CHECK(px_outside[0] > 250 && px_outside[1] < 5 && px_outside[2] < 5);

  // 8. mb_render_pixels_of() must restore both last_inst and the partial-redraw ground slot in vbuf.
  CHECK(mb_render_pixels_of(win1_inst, 2, 0.0, 0.0, 1.0, 1.0, 16, 16, px) == 1);
  ctx->ClearRenderTargetView(rtv, blue_clear);
  encode(rtv, fb_w, fb_h, last_count, last_bg, last_inst, &part);
  CHECK(read_off_bgra(12, 12, px_ground) == 1);
  CHECK(read_off_bgra(40, 40, px_green) == 1);
  CHECK(px_ground[2] > 250 && px_ground[1] < 5 && px_ground[0] < 5);
  CHECK(px_green[1] > 250 && px_green[2] < 5 && px_green[0] < 5);

  // Closing window 1 releases its vbuf without affecting window 0.
  mb_render_forget(1);
  if (win1_tex) win1_tex->Release();
  CHECK(render_wins[1].win_vbuf == NULL && render_wins[1].win_vbuf_cap == 0);
  CHECK(render_wins[0].win_vbuf == win0_vb);

  // 9. Multi-window glass_idle_tick: another window drawing without glass must not free shared glass levels
  //    while window 0 still has glass on screen; once no open window has glass, idle eviction still frees them.
  CHECK(ensure_levels(16, 16) == 1 && lv_w >= 16);
  render_wins[0].has_glass = 1;
  glass_idle_frames = 0;
  for (int i = 0; i < MB_GLASS_IDLE + 10; i++) {
    glass_drawn = 0;
    glass_idle_tick();
  }
  CHECK(lv_w >= 16);
  render_wins[0].has_glass = 0;
  for (int i = 0; i < MB_GLASS_IDLE; i++) {
    glass_drawn = 0;
    glass_idle_tick();
  }
  CHECK(lv_w == 0);

  if (failed) return 1;
  printf("win_vbuf: ok\n");
  return 0;
}
