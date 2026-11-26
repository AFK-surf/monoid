// D3D11 WARP unit tests for src/host/win_image.cpp:
//   cl.exe -nologo -EHsc -W3 -WX -D_CRT_SECURE_NO_WARNINGS -Isrc/host scripts/win_image_test.cpp \
//     -Foout/win_image/ -Feout/win_image/win_image_test.exe \
//     -link d3d11.lib windowscodecs.lib ole32.lib urlmon.lib shlwapi.lib shcore.lib runtimeobject.lib
//   out/win_image/win_image_test.exe
// Verifies:
// 1. MBRAWPRE uploads to DXGI_FORMAT_R8G8B8A8_UNORM and mb_host_image_pixels reads back exact premultiplied RGBA
//    (both unscaled asymmetric pixels and max_px downscaled).
// 2. Top-down 32-bit BI_RGB BMP uploads to DXGI_FORMAT_B8G8R8X8_UNORM and mb_host_image_pixels swaps R/B with alpha=255.
// 3. Regular PNG decoded via WIC uploads to DXGI_FORMAT_B8G8R8A8_UNORM and mb_host_image_pixels reads back premultiplied RGBA.
// 4. Malformed MBRAWPRE vectors fail directly with state == -1 without falling through to WIC.
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

typedef const wchar_t *moonbit_string_t;
typedef uint8_t *moonbit_bytes_t;
static size_t test_mb_len = 0;
static int32_t Moonbit_array_length(const void *) { return (int32_t)test_mb_len; }

static ID3D11Device *g_test_dev = NULL;
static ID3D11DeviceContext *g_test_ctx = NULL;

extern "C" {
void *mb_render_device(void) { return g_test_dev; }
void *mb_render_context(void) { return g_test_ctx; }
void mb_app_wake(void) {}
}

#include "win_image.cpp"

static int failed = 0;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      printf("%s:%d: failed: %s\n", __FILE__, __LINE__, #c);             \
      fflush(stdout);                                                    \
      failed = 1;                                                        \
    }                                                                    \
  } while (0)

static void put_le32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v & 0xFFu);
  p[1] = (uint8_t)((v >> 8) & 0xFFu);
  p[2] = (uint8_t)((v >> 16) & 0xFFu);
  p[3] = (uint8_t)((v >> 24) & 0xFFu);
}

static int wait_image(int id, double out[4]) {
  for (int i = 0; i < 500; i++) {
    int st = mb_host_image_info(id, out);
    if (st != 0) return st;
    Sleep(1);
  }
  return 0;
}

static uint8_t *make_raw_premul(uint32_t w, uint32_t h, size_t payload_len, size_t *total_len) {
  *total_len = 16u + payload_len;
  uint8_t *b = (uint8_t *)calloc(1, *total_len);
  memcpy(b, "MBRAWPRE", 8);
  put_le32(b + 8, w);
  put_le32(b + 12, h);
  return b;
}

// Build a valid top-down 32-bit BI_RGB BMP (BGRA bytes in memory, X byte set to 0 to verify alpha=255 readback).
static uint8_t *make_raw_bmp(int w, int h, uint8_t r, uint8_t g, uint8_t b, size_t *total_len) {
  size_t px_bytes = (size_t)w * (size_t)h * 4u;
  *total_len = 54u + px_bytes;
  uint8_t *buf = (uint8_t *)calloc(1, *total_len);
  buf[0] = 'B';
  buf[1] = 'M';
  put_le32(buf + 2, (uint32_t)*total_len);
  put_le32(buf + 10, 54u);
  put_le32(buf + 14, 40u);
  put_le32(buf + 18, (uint32_t)w);
  put_le32(buf + 22, (uint32_t)(-h));  // top-down
  buf[26] = 1;  // planes
  buf[28] = 32; // bpp
  for (int i = 0; i < w * h; i++) {
    buf[54 + i * 4 + 0] = b;
    buf[54 + i * 4 + 1] = g;
    buf[54 + i * 4 + 2] = r;
    buf[54 + i * 4 + 3] = 0;  // X channel intentionally 0
  }
  return buf;
}

// Encode a 2x2 BGRA PNG via WIC (GUID_WICPixelFormat32bppBGRA) so we test the real WIC -> B8G8R8A8_UNORM readback path.
static int make_wic_png_2x2(uint8_t **out_png, size_t *out_len) {
  *out_png = NULL;
  *out_len = 0;
  // 2x2 straight BGRA: pixel 0 = (B=50, G=100, R=200, A=128) -> premul RGBA ~(100, 50, 25, 128),
  //                    pixel 1 = (B=40, G=200, R=10,  A=255) -> premul RGBA  (10, 200, 40, 255).
  uint8_t bgra[2 * 2 * 4] = {
      50, 100, 200, 128,   40, 200,  10, 255,
      40, 200,  10, 255,   50, 100, 200, 128,
  };
  IWICImagingFactory *wic = NULL;
  IStream *stream = NULL;
  IWICBitmapEncoder *enc = NULL;
  IWICBitmapFrameEncode *frame = NULL;
  int ok = 0;
  WICPixelFormatGUID fmt = GUID_WICPixelFormat32bppBGRA;
  if (SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic))) &&
      SUCCEEDED(CreateStreamOnHGlobal(NULL, TRUE, &stream)) &&
      SUCCEEDED(wic->CreateEncoder(GUID_ContainerFormatPng, NULL, &enc)) &&
      SUCCEEDED(enc->Initialize(stream, WICBitmapEncoderNoCache)) &&
      SUCCEEDED(enc->CreateNewFrame(&frame, NULL)) &&
      SUCCEEDED(frame->Initialize(NULL)) &&
      SUCCEEDED(frame->SetSize(2, 2)) &&
      SUCCEEDED(frame->SetPixelFormat(&fmt)) &&
      IsEqualGUID(fmt, GUID_WICPixelFormat32bppBGRA) &&
      SUCCEEDED(frame->WritePixels(2, 2 * 4, (UINT)sizeof(bgra), bgra)) &&
      SUCCEEDED(frame->Commit()) &&
      SUCCEEDED(enc->Commit())) {
    HGLOBAL hg = NULL;
    STATSTG st = {};
    if (SUCCEEDED(GetHGlobalFromStream(stream, &hg)) && SUCCEEDED(stream->Stat(&st, STATFLAG_NONAME))) {
      size_t n = (size_t)st.cbSize.QuadPart;
      const void *p = GlobalLock(hg);
      *out_png = (uint8_t *)malloc(n ? n : 1);
      if (p && *out_png) {
        memcpy(*out_png, p, n);
        *out_len = n;
        ok = 1;
      }
      if (p) GlobalUnlock(hg);
    }
  }
  if (frame) frame->Release();
  if (enc) enc->Release();
  if (stream) stream->Release();
  if (wic) wic->Release();
  return ok;
}

int main(void) {
  HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  CHECK(SUCCEEDED(co));

  D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_0;
  HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_WARP, NULL, 0, &fl, 1, D3D11_SDK_VERSION,
                                 &g_test_dev, NULL, &g_test_ctx);
  CHECK(SUCCEEDED(hr) && g_test_dev && g_test_ctx);
  if (!g_test_dev || !g_test_ctx) return 1;

  // 1a. MBRAWPRE unscaled -> DXGI_FORMAT_R8G8B8A8_UNORM + exact readback
  {
    size_t len = 0;
    uint8_t *buf = make_raw_premul(2, 1, 8, &len);
    buf[16] = 100; buf[17] = 50; buf[18] = 25; buf[19] = 128;
    buf[20] = 255; buf[21] = 0;  buf[22] = 10; buf[23] = 255;
    test_mb_len = len;
    int id = mb_host_image_load_bytes(buf, 64);
    free(buf);
    double info[4] = {};
    CHECK(wait_image(id, info) == 1);
    CHECK(info[0] == 2.0 && info[1] == 1.0 && info[2] == 2.0 && info[3] == 1.0);
    uint8_t out[8] = {};
    test_mb_len = sizeof(out);
    CHECK(mb_host_image_pixels(id, out) == 1);
    CHECK(out[0] == 100 && out[1] == 50 && out[2] == 25 && out[3] == 128);
    CHECK(out[4] == 255 && out[5] == 0  && out[6] == 10 && out[7] == 255);
    mb_host_image_free(id);
  }

  // 1b. MBRAWPRE downscaled (8x4 with max_px=4 -> 4x2, ow=8, oh=4)
  {
    size_t len = 0;
    uint8_t *buf = make_raw_premul(8, 4, 8u * 4u * 4u, &len);
    for (int i = 0; i < 8 * 4; i++) {
      buf[16 + i * 4 + 0] = 80;
      buf[16 + i * 4 + 1] = 40;
      buf[16 + i * 4 + 2] = 20;
      buf[16 + i * 4 + 3] = 128;
    }
    test_mb_len = len;
    int id = mb_host_image_load_bytes(buf, 4);
    free(buf);
    double info[4] = {};
    CHECK(wait_image(id, info) == 1);
    CHECK(info[0] == 4.0 && info[1] == 2.0 && info[2] == 8.0 && info[3] == 4.0);
    uint8_t out[4 * 2 * 4] = {};
    test_mb_len = sizeof(out);
    CHECK(mb_host_image_pixels(id, out) == 1);
    CHECK(out[0] == 80 && out[1] == 40 && out[2] == 20 && out[3] == 128);
    mb_host_image_free(id);
  }

  // 2. raw_bmp -> DXGI_FORMAT_B8G8R8X8_UNORM + RB swap and alpha=255
  {
    size_t len = 0;
    uint8_t *bmp = make_raw_bmp(2, 2, 210, 90, 30, &len);
    test_mb_len = len;
    int id = mb_host_image_load_bytes(bmp, 64);
    free(bmp);
    double info[4] = {};
    CHECK(wait_image(id, info) == 1);
    CHECK(info[0] == 2.0 && info[1] == 2.0);
    uint8_t out[2 * 2 * 4] = {};
    test_mb_len = sizeof(out);
    CHECK(mb_host_image_pixels(id, out) == 1);
    CHECK(out[0] == 210 && out[1] == 90 && out[2] == 30 && out[3] == 255);
    mb_host_image_free(id);
  }

  // 3. Regular PNG via WIC -> DXGI_FORMAT_B8G8R8A8_UNORM + premultiplied RGBA readback
  {
    uint8_t *png = NULL;
    size_t len = 0;
    CHECK(make_wic_png_2x2(&png, &len) == 1);
    if (png) {
      test_mb_len = len;
      int id = mb_host_image_load_bytes(png, 64);
      free(png);
      double info[4] = {};
      CHECK(wait_image(id, info) == 1);
      CHECK(info[0] == 2.0 && info[1] == 2.0);
      uint8_t out[2 * 2 * 4] = {};
      test_mb_len = sizeof(out);
      CHECK(mb_host_image_pixels(id, out) == 1);
      // Pixel 0: straight (200,100,50,128) -> premul ~(100,50,25,128)
      CHECK(out[0] >= 99 && out[0] <= 101);
      CHECK(out[1] >= 49 && out[1] <= 51);
      CHECK(out[2] >= 24 && out[2] <= 26);
      CHECK(out[3] == 128);
      // Pixel 1: opaque (10,200,40,255)
      CHECK(out[4] == 10 && out[5] == 200 && out[6] == 40 && out[7] == 255);
      mb_host_image_free(id);
    }
  }

  // 4. Malformed MBRAWPRE vectors fail with state == -1
  {
    const uint8_t trunc_hdr[12] = {'M', 'B', 'R', 'A', 'W', 'P', 'R', 'E', 1, 0, 0, 0};
    test_mb_len = sizeof(trunc_hdr);
    int id0 = mb_host_image_load_bytes((uint8_t *)trunc_hdr, 64);
    double info[4] = {};
    CHECK(wait_image(id0, info) == -1);
    mb_host_image_free(id0);

    struct { uint32_t w, h; size_t pay; } bads[] = {
        {2, 2, 12},
        {0, 2, 0},
        {2, 0, 0},
        {16385, 1, 0},
        {65536, 65536, 0},
        {1, 1, 5},
    };
    for (size_t i = 0; i < sizeof(bads) / sizeof(bads[0]); i++) {
      size_t len = 0;
      uint8_t *b = make_raw_premul(bads[i].w, bads[i].h, bads[i].pay, &len);
      test_mb_len = len;
      int id = mb_host_image_load_bytes(b, 64);
      free(b);
      CHECK(wait_image(id, info) == -1);
      mb_host_image_free(id);
    }
  }

  g_test_ctx->Release();
  g_test_dev->Release();
  if (SUCCEEDED(co)) CoUninitialize();
  if (failed) return 1;
  printf("win_image_test: OK\n");
  return 0;
}
