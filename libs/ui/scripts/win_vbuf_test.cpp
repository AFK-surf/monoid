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

static int fail_map_vbuf_count = 0;
static int map_vbuf_calls = 0;
static HRESULT test_map_vbuf(ID3D11DeviceContext *c, ID3D11Buffer *b, D3D11_MAPPED_SUBRESOURCE *m) {
  map_vbuf_calls++;
  if (fail_map_vbuf_count > 0) {
    fail_map_vbuf_count--;
    return E_OUTOFMEMORY;
  }
  return c->Map(b, 0, D3D11_MAP_WRITE_DISCARD, 0, m);
}
#define MB_WIN_MAP_VBUF(c, b, m) test_map_vbuf((c), (b), (m))

static int dcomp_commit_calls = 0;
static HRESULT test_dcomp_commit(void *) {
  dcomp_commit_calls++;
  return S_OK;
}
#define MB_WIN_DCOMP_COMMIT(dc) test_dcomp_commit((dc))

static int32_t test_atlas_gen = 0;
static uint64_t test_image_gen = 0;
static uint64_t test_image_free_gen = 0;

extern "C" {
const wchar_t *mb_win_env(const wchar_t *) { return NULL; }
const wchar_t *mb_win_app_id(void) { return L""; }
void mb_host_request_frame(void) {}
void *mb_image_srv(int) { return NULL; }
uint64_t mb_image_generation(void) { return test_image_gen; }
uint64_t mb_image_free_generation(void) { return test_image_free_gen; }
void *mb_stream_srv(int) { return NULL; }
void mb_text_set_scale(double) {}
int32_t mb_atlas_gen_now(void) { return test_atlas_gen; }
int mb_views_count(void) { return 0; }
void mb_views_draw_under(uint8_t *, int, int, double) {}
double mb_app_scale(void) { return 1.0; }
}

#include "win_reveal.h"
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

  // Lightweight mock IDXGISwapChain1 to exercise flip+DComp same_as_shown, Present/Present1, occlusion, and glass.
  struct FakeSwapChain1 : public IDXGISwapChain1 {
    ULONG refs = 1;
    HRESULT next_hr = S_OK;
    int present_full_calls = 0;
    int present1_calls = 0;
    UINT last_dirty_count = 0;
    UINT present_count = 0;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, void **ppv) override {
      if (ppv) *ppv = NULL;
      return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef(void) override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release(void) override { return refs > 0 ? --refs : 0; }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID, UINT, const void *) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID, const IUnknown *) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID, UINT *, void *) override { return E_FAIL; }
    HRESULT STDMETHODCALLTYPE GetParent(REFIID, void **ppv) override {
      if (ppv) *ppv = NULL;
      return E_NOINTERFACE;
    }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID, void **ppv) override {
      if (ppv) *ppv = NULL;
      return E_NOINTERFACE;
    }
    HRESULT STDMETHODCALLTYPE Present(UINT, UINT) override {
      present_full_calls++;
      HRESULT hr = next_hr;
      next_hr = S_OK;
      if (SUCCEEDED(hr) && hr != DXGI_STATUS_OCCLUDED) present_count++;
      return hr;
    }
    HRESULT STDMETHODCALLTYPE GetBuffer(UINT, REFIID, void **ppv) override {
      if (ppv) *ppv = NULL;
      return E_FAIL;
    }
    HRESULT STDMETHODCALLTYPE SetFullscreenState(BOOL, IDXGIOutput *) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetFullscreenState(BOOL *fs, IDXGIOutput **out) override {
      if (fs) *fs = FALSE;
      if (out) *out = NULL;
      return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetDesc(DXGI_SWAP_CHAIN_DESC *) override { return E_FAIL; }
    HRESULT STDMETHODCALLTYPE ResizeBuffers(UINT, UINT, UINT, DXGI_FORMAT, UINT) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE ResizeTarget(const DXGI_MODE_DESC *) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetContainingOutput(IDXGIOutput **out) override {
      if (out) *out = NULL;
      return E_FAIL;
    }
    HRESULT STDMETHODCALLTYPE GetFrameStatistics(DXGI_FRAME_STATISTICS *) override { return E_FAIL; }
    HRESULT STDMETHODCALLTYPE GetLastPresentCount(UINT *c) override {
      if (c) *c = present_count;
      return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetDesc1(DXGI_SWAP_CHAIN_DESC1 *) override { return E_FAIL; }
    HRESULT STDMETHODCALLTYPE GetFullscreenDesc(DXGI_SWAP_CHAIN_FULLSCREEN_DESC *) override { return E_FAIL; }
    HRESULT STDMETHODCALLTYPE GetHwnd(HWND *) override { return E_FAIL; }
    HRESULT STDMETHODCALLTYPE GetCoreWindow(REFIID, void **ppv) override {
      if (ppv) *ppv = NULL;
      return E_NOINTERFACE;
    }
    HRESULT STDMETHODCALLTYPE Present1(UINT, UINT, const DXGI_PRESENT_PARAMETERS *pp) override {
      present1_calls++;
      last_dirty_count = pp ? pp->DirtyRectsCount : 0;
      HRESULT hr = next_hr;
      next_hr = S_OK;
      if (SUCCEEDED(hr) && hr != DXGI_STATUS_OCCLUDED) present_count++;
      return hr;
    }
    BOOL STDMETHODCALLTYPE IsTemporaryMonoSupported(void) override { return FALSE; }
    HRESULT STDMETHODCALLTYPE GetRestrictToOutput(IDXGIOutput **out) override {
      if (out) *out = NULL;
      return E_FAIL;
    }
    HRESULT STDMETHODCALLTYPE SetBackgroundColor(const DXGI_RGBA *) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetBackgroundColor(DXGI_RGBA *) override { return E_FAIL; }
    HRESULT STDMETHODCALLTYPE SetRotation(DXGI_MODE_ROTATION) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetRotation(DXGI_MODE_ROTATION *) override { return E_FAIL; }
  };

  auto read_tex_bgra = [](ID3D11Texture2D *tex, int x, int y, uint8_t out[4]) -> int {
    D3D11_TEXTURE2D_DESC td = {};
    tex->GetDesc(&td);
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Texture2D *st = NULL;
    if (FAILED(dev->CreateTexture2D(&td, NULL, &st)) || !st) return 0;
    ctx->CopyResource(st, tex);
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

  auto read_uncached_ref_bgra = [](int x, int y, uint8_t out[4]) -> int {
    slots_invalidate();
    ID3D11Texture2D *st = redrawn(fb_w, fb_h);
    if (!st) return 0;
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

  auto fill_solid_rgba = [](uint8_t *buf, int w, int h, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    for (int i = 0; i < w * h; i++) {
      buf[i * 4 + 0] = r;
      buf[i * 4 + 1] = g;
      buf[i * 4 + 2] = b;
      buf[i * 4 + 3] = a;
    }
  };

  // Scene with an atlas quad (kind 3) on the left [8..56, 8..56] covered by frosted glass (kind 5) [12..52, 12..52]
  // and a small cursor rect on the right [96..104, 16..32].
  static double glass_scene[3 * MB_INST];
  memset(glass_scene, 0, sizeof glass_scene);
  {
    // [0]: atlas color quad on the left, sampling atlas texels (0, 0, 16, 16)
    double *a = glass_scene + 0 * MB_INST;
    a[0] = 8.0; a[1] = 8.0; a[2] = 48.0; a[3] = 48.0;
    a[5] = 3.0;
    a[8] = 1.0; a[9] = 1.0; a[10] = 1.0; a[11] = 1.0;
    a[12] = 0.0; a[13] = 0.0; a[14] = 16.0; a[15] = 16.0;
    a[16] = -1e9; a[17] = -1e9; a[18] = 1e9; a[19] = 1e9;
    // [1]: right-side cursor rect (x in [112..120], strictly outside glass blur dependency x <= 84 + 14 = 98)
    double *c = glass_scene + 1 * MB_INST;
    c[0] = 112.0; c[1] = 16.0; c[2] = 8.0; c[3] = 16.0;
    c[5] = 0.0;
    c[8] = 1.0; c[9] = 1.0; c[10] = 0.0; c[11] = 1.0;
    c[16] = -1e9; c[17] = -1e9; c[18] = 1e9; c[19] = 1e9;
    // [2]: opaque frosted glass (g[6]=sat 1.0, g[15]=opacity 1.0) covering left atlas quad [12..56] and bare bg [56..84]
    double *g = glass_scene + 2 * MB_INST;
    g[0] = 12.0; g[1] = 12.0; g[2] = 72.0; g[3] = 40.0;
    g[4] = 4.0; g[5] = 5.0; g[6] = 1.0; g[7] = 4.0;
    g[8] = 1.0; g[9] = 1.0; g[10] = 1.0; g[11] = 0.15;
    g[15] = 1.0;
    g[16] = -1e9; g[17] = -1e9; g[18] = 1e9; g[19] = 1e9;
    g[20] = -1.0;
  }

  uint8_t atlas_red[16 * 16 * 4], atlas_blue[16 * 16 * 4], atlas_green[16 * 16 * 4];
  fill_solid_rgba(atlas_red, 16, 16, 240, 20, 20, 255);
  fill_solid_rgba(atlas_blue, 16, 16, 20, 40, 240, 255);
  fill_solid_rgba(atlas_green, 16, 16, 20, 230, 40, 255);
  mb_atlas_upload(0, 0, 16, 16, atlas_red);

  FakeSwapChain1 fake_sc0, fake_sc1;
  IDCompositionDevice *saved_dcomp = dcomp;
  int saved_flip = flip_chain;
  dcomp = (IDCompositionDevice *)1;
  flip_chain = 1;

  mb_render_use(0);
  chain = &fake_sc0;
  rw->shown_ok = 0;
  rw->swap_needs_full = 0;
  rw->commit_owed = 0;
  canvas_ok = 0;

  // 10. same_as_shown skip hit: identical frame skips Map(vbuf), Present1, and ad_frame_serial increment.
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 0) == 1);
  CHECK(rw->shown_ok == 1 && mb_render_last_presented(0) == 1);
  CHECK(fake_sc0.present_full_calls == 1 && fake_sc0.present1_calls == 0);
  int map_before = map_vbuf_calls;
  uint64_t serial_before = rw->ad_frame_serial;
  mb_host_render_dirty(112.0, 16.0, 8.0, 16.0);
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 0) == 0);
  CHECK(mb_render_last_presented(0) == 0);
  CHECK(map_vbuf_calls == map_before);
  CHECK(fake_sc0.present_full_calls == 1 && fake_sc0.present1_calls == 0);
  CHECK(dirty_told == 0 && dirty_whole == 0 && dirty_n == 0);
  CHECK(rw->ad_frame_serial == serial_before);

  // 11. Left-side shared UV overwrite + right-side-only cursor damage: must invalidate canvas & glass cache,
  //     and pixels inside the left glass-covered region must match a fresh uncached full draw.
  uint8_t px_before[4] = {}, px_after[4] = {}, px_ref[4] = {};
  CHECK(read_tex_bgra(off_target, 32, 32, px_before) == 1);
  mb_atlas_upload(0, 0, 16, 16, atlas_blue);  // overwrite existing UV (0,0,16,16)
  glass_scene[1 * MB_INST + 8] = 0.0;         // change right cursor slightly
  mb_host_render_dirty(112.0, 16.0, 8.0, 16.0);  // report ONLY right-side cursor damage!
  int full_before = fake_sc0.present_full_calls;
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 0) == 1);
  CHECK(fake_sc0.present_full_calls == full_before + 1);  // whole-canvas redraw forced
  CHECK(read_tex_bgra(off_target, 32, 32, px_after) == 1);
  CHECK(read_uncached_ref_bgra(32, 32, px_ref) == 1);
  CHECK(abs((int)px_after[0] - (int)px_ref[0]) <= 2 && abs((int)px_after[1] - (int)px_ref[1]) <= 2 &&
        abs((int)px_after[2] - (int)px_ref[2]) <= 2);
  CHECK(px_after[0] > px_before[0] + 80);  // blue channel jumped under glass

  // 12. Cross-window shared UV overwrite: window 1 is already shown_ok; window 0 overwrites shared UV;
  //     window 1 must NOT skip and must match a fresh uncached full draw under glass.
  D3D11_TEXTURE2D_DESC td2 = {};
  td2.Width = 128; td2.Height = 128; td2.MipLevels = td2.ArraySize = 1;
  td2.Format = DXGI_FORMAT_B8G8R8A8_UNORM; td2.SampleDesc.Count = 1;
  td2.Usage = D3D11_USAGE_DEFAULT; td2.BindFlags = D3D11_BIND_RENDER_TARGET;
  ID3D11Texture2D *w1_tex = NULL;
  ID3D11RenderTargetView *w1_rtv = NULL;
  CHECK(SUCCEEDED(dev->CreateTexture2D(&td2, NULL, &w1_tex)) && w1_tex != NULL);
  CHECK(SUCCEEDED(dev->CreateRenderTargetView(w1_tex, NULL, &w1_rtv)) && w1_rtv != NULL);
  mb_render_use(1);
  render_win_fresh(rw);
  chain = &fake_sc1;
  rtv = w1_rtv;
  fb_w = 128; fb_h = 128; vw = 128.0; vh = 128.0; vscale = 1.0;
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 0) == 1);
  CHECK(rw->shown_ok == 1);
  // Overwrite shared UV while window 0 is active!
  mb_render_use(0);
  mb_atlas_upload(0, 0, 16, 16, atlas_green);
  // Now present window 1 with identical instances & empty damage: must NOT skip and must show green under glass!
  mb_render_use(1);
  mb_host_render_dirty(0.0, 0.0, 0.0, 0.0);
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 0) == 1);
  uint8_t w1_px[4] = {}, w1_ref[4] = {};
  CHECK(read_tex_bgra(w1_tex, 32, 32, w1_px) == 1);
  CHECK(read_uncached_ref_bgra(32, 32, w1_ref) == 1);
  CHECK(abs((int)w1_px[0] - (int)w1_ref[0]) <= 2 && abs((int)w1_px[1] - (int)w1_ref[1]) <= 2 &&
        abs((int)w1_px[2] - (int)w1_ref[2]) <= 2);
  CHECK(w1_px[1] > 120);  // green channel high under glass

  // 13. Normal glyph append (non-overlapping UV) + non-empty damage preserves partial redraw (Present1, np > 0),
  //     keeps existing GlassSlot cache valid (no reblur on fresh glyph append), and preserves idle window 0's skip!
  mb_render_use(0);
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 0) == 1);  // sync window 0 to green
  int slot_before_append = last_captured_slot;
  CHECK(slot_before_append >= 0);
  int w0_pfull = fake_sc0.present_full_calls, w0_p1 = fake_sc0.present1_calls;
  mb_atlas_upload(32, 0, 16, 16, atlas_red);  // fresh non-overlapping UV
  // Window 1 gets right-side cursor change + non-empty damage -> must stay partial (Present1)!
  mb_render_use(1);
  int w1_pfull = fake_sc1.present_full_calls, w1_p1 = fake_sc1.present1_calls;
  glass_scene[1 * MB_INST + 9] = 0.25;
  mb_host_render_dirty(112.0, 16.0, 8.0, 16.0);
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 0) == 1);
  CHECK(fake_sc1.present1_calls == w1_p1 + 1 && fake_sc1.present_full_calls == w1_pfull);
  CHECK(fake_sc1.last_dirty_count == 1);
  // Fresh glyph append with no overwrite keeps the exact same GlassSlot hit when glass is re-encoded.
  glass_scene[1 * MB_INST + 9] = 0.5;
  unsigned clock_before_append = gslots_clock;
  mb_host_render_dirty(12.0, 12.0, 72.0, 40.0);
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 0) == 1);
  CHECK(last_captured_slot == slot_before_append && gslots[last_captured_slot].used > clock_before_append);
  CHECK(gslots[last_captured_slot].atlas_overwrite_seq == g_atlas_overwrite_seq);
  // Meanwhile window 0 with unchanged scene still hits same_as_shown skip!
  mb_render_use(0);
  glass_scene[1 * MB_INST + 9] = 1.0;  // restore window 0's scene
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 0) == 0);
  CHECK(fake_sc0.present_full_calls == w0_pfull && fake_sc0.present1_calls == w0_p1);

  // 14. clear change + empty damage forces whole-window redraw and refreshes opaque frosted glass blur over bare bg.
  //     Use bright bg (0.8, 0.4, 0.2) so opaque glass (g[15]=1.0, tint 0.15) blurs bg RGB (~211 R) under clear=0 vs
  //     transparent (0,0,0,0 -> ~38 R) under clear=1; reusing stale blur would leave R near ~211 and fail!
  CHECK(mb_render_present_opts(glass_scene, 3, 0.8, 0.4, 0.2, 0) == 1);
  uint8_t cl0_px[4] = {}, cl1_px[4] = {}, cl1_ref[4] = {};
  CHECK(read_tex_bgra(off_target, 76, 32, cl0_px) == 1);  // inside opaque glass, >3*blur_r past atlas quad
  CHECK(cl0_px[2] > 180 && cl0_px[3] > 250);
  mb_render_set_clear(0, 1);
  mb_host_render_dirty(0.0, 0.0, 0.0, 0.0);
  w0_pfull = fake_sc0.present_full_calls;
  CHECK(mb_render_present_opts(glass_scene, 3, 0.8, 0.4, 0.2, 0) == 1);
  CHECK(fake_sc0.present_full_calls == w0_pfull + 1);
  CHECK(read_tex_bgra(off_target, 76, 32, cl1_px) == 1);
  CHECK(read_uncached_ref_bgra(76, 32, cl1_ref) == 1);
  CHECK(cl1_px[2] + 100 < cl0_px[2]);  // glass blurred RGB dropped sharply (clear=1 transparent vs clear=0 bright bg)
  CHECK(abs((int)cl1_px[0] - (int)cl1_ref[0]) <= 2 && abs((int)cl1_px[1] - (int)cl1_ref[1]) <= 2 &&
        abs((int)cl1_px[2] - (int)cl1_ref[2]) <= 2 && abs((int)cl1_px[3] - (int)cl1_ref[3]) <= 2);
  mb_render_set_clear(0, 0);
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 0) == 1);

  // 15. DXGI_STATUS_OCCLUDED sets swap_needs_full = 1 and shown_ok = 0; next visible present uses full Present(1, 0).
  fake_sc0.next_hr = DXGI_STATUS_OCCLUDED;
  glass_scene[1 * MB_INST + 8] = 0.5;
  mb_host_render_dirty(112.0, 16.0, 8.0, 16.0);
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 0) == 1);  // SUCCEEDED(DXGI_STATUS_OCCLUDED)
  CHECK(mb_render_last_presented(0) == 0);
  CHECK(rw->shown_ok == 0 && rw->swap_needs_full == 1);
  w0_pfull = fake_sc0.present_full_calls;
  w0_p1 = fake_sc0.present1_calls;
  mb_host_render_dirty(112.0, 16.0, 8.0, 16.0);
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 0) == 1);
  CHECK(mb_render_last_presented(0) == 1);
  CHECK(fake_sc0.present_full_calls == w0_pfull + 1 && fake_sc0.present1_calls == w0_p1);
  CHECK(rw->shown_ok == 1 && rw->swap_needs_full == 0);

  // 16. must_present == 1 bypasses same_as_shown skip even on identical frame;
  //     Map(vbuf) OOM returns 0 (keeps window cloaked for retry), whereas DXGI_STATUS_OCCLUDED returns 1.
  w0_p1 = fake_sc0.present1_calls;
  mb_host_render_dirty(0.0, 0.0, 0.0, 0.0);
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 1) == 1);
  CHECK(mb_render_last_presented(0) == 1 && fake_sc0.present1_calls == w0_p1 + 1);
  fail_map_vbuf_count = 1;
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 1) == 0);
  CHECK(mb_render_last_presented(0) == 0);
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 1) == 1);
  CHECK(mb_render_last_presented(0) == 1);
  fake_sc0.next_hr = DXGI_STATUS_OCCLUDED;
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 1) == 1);
  CHECK(mb_render_last_presented(0) == 0 && rw->swap_needs_full == 1);
  CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 1) == 1);
  CHECK(mb_render_last_presented(0) == 1 && rw->swap_needs_full == 0);

  // 16b. Host reveal state machine (win_reveal.h): 9 consecutive Map(vbuf) failures stay cloaked,
  //      exhaust fast retries onto the 250 ms paced_at backoff timer, and uncloak on attempt 10 recovery;
  //      DXGI_STATUS_OCCLUDED reveals immediately on attempt 1.
  {
    int held = 0, win0_rev = 0, to_show = 1, shown = 0, retries = 0, want = 1;
    double paced_at = -1.0, paced_margin = 0.0, sim_now = 1000.0;
    int calls = 0, revealed = 0;
    fail_map_vbuf_count = 9;
    while (!shown && calls < 16) {
      if (!want) {
        CHECK(paced_at >= sim_now);
        sim_now = paced_at;
        paced_at = -1.0;
        paced_margin = 0.0;
        want = 1;
      }
      want = 0;
      paced_at = -1.0;
      int sub = 0, pres = 0;
      int mp = mb_win_must_present(held, 1, win0_rev, to_show, shown);
      CHECK(mp == 1);
      int ok = mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, mp);
      int vis = mb_render_last_presented(0);
      mb_win_on_present_result(mp, ok, vis, 1, 0, 128.0, 128.0, sim_now,
                               &held, &win0_rev, &sub, &pres, &retries, &want, &paced_at, &paced_margin);
      calls++;
      if (mb_win_try_reveal_win0(&to_show, &shown, 1, sub)) revealed = 1;
      if (calls < 9) {
        CHECK(!shown && want == 1 && paced_at < 0.0);
      } else if (calls == 9) {
        CHECK(!shown && want == 0 && paced_at == sim_now + MB_WIN_RETRY_BACKOFF_MS);
      }
    }
    CHECK(calls == 10 && shown == 1 && to_show == 0 && revealed == 1 && retries == 0 && want == 0);
  }
  {
    // Secondary held window: 9 consecutive submit failures -> backoff -> attempt 10 recovery uncloaks;
    // OCCLUDED on attempt 1 reveals immediately.
    int held = 1, win0_rev = 0, to_show = 0, shown = 1, retries = 0, want = 1;
    double paced_at = -1.0, paced_margin = 0.0, sim_now = 2000.0;
    int calls = 0;
    fail_map_vbuf_count = 9;
    while (held != 2 && calls < 16) {
      if (!want) {
        CHECK(paced_at >= sim_now);
        sim_now = paced_at;
        paced_at = -1.0;
        want = 1;
      }
      want = 0;
      paced_at = -1.0;
      int sub = 0, pres = 0;
      int mp = mb_win_must_present(held, 0, win0_rev, to_show, shown);
      int ok = mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, mp);
      mb_win_on_present_result(mp, ok, mb_render_last_presented(0), 0, 0, 128.0, 128.0, sim_now,
                               &held, &win0_rev, &sub, &pres, &retries, &want, &paced_at, &paced_margin);
      calls++;
    }
    CHECK(calls == 10 && held == 2 && retries == 0 && want == 0);

    // Primary window under DXGI_STATUS_OCCLUDED reveals immediately on attempt 1.
    held = 0; win0_rev = 0; to_show = 1; shown = 0; retries = 0; want = 0; paced_at = -1.0;
    int sub = 0, pres = 0;
    fake_sc0.next_hr = DXGI_STATUS_OCCLUDED;
    int mp = mb_win_must_present(held, 1, win0_rev, to_show, shown);
    int ok = mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, mp);
    mb_win_on_present_result(mp, ok, mb_render_last_presented(0), 1, 0, 128.0, 128.0, 3000.0,
                             &held, &win0_rev, &sub, &pres, &retries, &want, &paced_at, &paced_margin);
    CHECK(mb_win_try_reveal_win0(&to_show, &shown, 1, sub) == 1);
    CHECK(shown == 1 && to_show == 0 && sub == 1 && pres == 0 && want == 0 && paced_at < 0.0);
    // Restore swap_needs_full before test 18
    CHECK(mb_render_present_opts(glass_scene, 3, 0.1, 0.1, 0.1, 1) == 1);
  }

  // 17. mb_render_pace_skipped() sets pace_owed = 1 from 0, and preserves 2 (occluded).
  pace_owed = 0;
  mb_render_pace_skipped();
  CHECK(pace_owed == 1);
  pace_owed = 2;
  mb_render_pace_skipped();
  CHECK(pace_owed == 2);
  pace_owed = 0;

  // 18. Map(vbuf) failure OOM in both submit() and fill_vbuf() releases vbuf and preserves last_inst/last_count/last_bg.
  int32_t saved_lc = last_count;
  float saved_bg[3] = {last_bg[0], last_bg[1], last_bg[2]};
  size_t saved_bytes = (size_t)saved_lc * MB_INST * sizeof(float);
  float *saved_inst = (float *)malloc(saved_bytes ? saved_bytes : 1);
  CHECK(saved_inst != NULL);
  if (saved_inst && saved_bytes > 0) memcpy(saved_inst, last_inst, saved_bytes);
  fail_map_vbuf_count = 1;
  CHECK(submit(inst, 16, 0.9, 0.8, 0.7) == 0);
  CHECK(vbuf == NULL && vbuf_cap == 0);
  CHECK(last_count == saved_lc && last_bg[0] == saved_bg[0] && last_bg[1] == saved_bg[1] && last_bg[2] == saved_bg[2]);
  CHECK(saved_bytes == 0 || (last_inst != NULL && memcmp(last_inst, saved_inst, saved_bytes) == 0));
  fail_map_vbuf_count = 1;
  CHECK(fill_vbuf(finst, 16) == 0);
  CHECK(vbuf == NULL && vbuf_cap == 0);
  CHECK(last_count == saved_lc && last_bg[0] == saved_bg[0] && last_bg[1] == saved_bg[1] && last_bg[2] == saved_bg[2]);
  CHECK(saved_bytes == 0 || (last_inst != NULL && memcmp(last_inst, saved_inst, saved_bytes) == 0));
  free(saved_inst);
  CHECK(submit(inst, 16, 0.9, 0.8, 0.7) == 1);
  CHECK(vbuf != NULL && vbuf_cap > 0);

  // Clean up mock swapchain/dcomp before mb_render_forget(1).
  mb_render_use(1);
  chain = NULL;
  dcomp = saved_dcomp;
  flip_chain = saved_flip;
  mb_render_forget(1);
  if (w1_tex) w1_tex->Release();
  mb_render_use(0);
  chain = NULL;

  if (failed) return 1;
  printf("win_vbuf: ok\n");
  return 0;
}
