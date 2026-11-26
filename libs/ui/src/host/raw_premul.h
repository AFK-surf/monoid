// Shared MBRAWPRE binary wire format parser, bounds validator, and premultiplied RGBA8888 downscaler.
// Pure C99/C++ compatible, zero platform dependencies.
//
// Wire format (version 1, little-endian, 16 + w * h * 4 bytes):
//   [0..8)   ASCII magic "MBRAWPRE"
//   [8..12)  uint32_t w (1..=16384)
//   [12..16) uint32_t h (1..=16384)
//   [16..)   tight row-major top-down premultiplied sRGB RGBA8888 (stride = w * 4)
#ifndef MB_RAW_PREMUL_H
#define MB_RAW_PREMUL_H

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define MB_RAW_PREMUL_HEADER_BYTES 16u
#define MB_RAW_PREMUL_MAX_DIM 16384u

static inline int mb_raw_premul_is(const uint8_t *d, size_t n) {
  return d != NULL && n >= 8u && memcmp(d, "MBRAWPRE", 8u) == 0;
}

static inline int mb_raw_premul_parse(const uint8_t *d, size_t n, int *w, int *h) {
  if (!mb_raw_premul_is(d, n) || n < MB_RAW_PREMUL_HEADER_BYTES) return 0;
  uint32_t rw = (uint32_t)d[8] | ((uint32_t)d[9] << 8) | ((uint32_t)d[10] << 16) | ((uint32_t)d[11] << 24);
  uint32_t rh = (uint32_t)d[12] | ((uint32_t)d[13] << 8) | ((uint32_t)d[14] << 16) | ((uint32_t)d[15] << 24);
  if (rw == 0u || rh == 0u || rw > MB_RAW_PREMUL_MAX_DIM || rh > MB_RAW_PREMUL_MAX_DIM) return 0;
  uint64_t expected = (uint64_t)rw * (uint64_t)rh * 4ULL;
  if (expected != (uint64_t)(n - MB_RAW_PREMUL_HEADER_BYTES)) return 0;
  if (w) *w = (int)rw;
  if (h) *h = (int)rh;
  return 1;
}

static inline void mb_raw_premul_target_size(int w, int h, int max_px, int device_max, int *tw, int *th) {
  int dmax = device_max > 0 ? device_max : (int)MB_RAW_PREMUL_MAX_DIM;
  int lim = (max_px > 0 && max_px < dmax) ? max_px : dmax;
  if (w <= lim && h <= lim) {
    *tw = w;
    *th = h;
    return;
  }
  double k = (double)lim / (double)(w > h ? w : h);
  int rw = (int)lround((double)w * k);
  int rh = (int)lround((double)h * k);
  if (rw < 1) rw = 1;
  if (rw > lim) rw = lim;
  if (rh < 1) rh = 1;
  if (rh > lim) rh = lim;
  *tw = rw;
  *th = rh;
}

static inline void mb_raw_premul_downscale(const uint8_t *src, int sw, int sh, uint8_t *dst, int dw, int dh) {
  double sx_scale = (double)sw / (double)dw;
  double sy_scale = (double)sh / (double)dh;
  for (int y = 0; y < dh; y++) {
    double fy = ((double)y + 0.5) * sy_scale - 0.5;
    int y0 = fy < 0.0 ? 0 : (int)fy;
    if (y0 >= sh) y0 = sh - 1;
    int y1 = y0 + 1 < sh ? y0 + 1 : sh - 1;
    double wy = (fy < 0.0 || fy >= (double)(sh - 1)) ? 0.0 : (fy - (double)y0);
    double wy0 = 1.0 - wy;
    const uint8_t *row0 = src + (size_t)y0 * (size_t)sw * 4u;
    const uint8_t *row1 = src + (size_t)y1 * (size_t)sw * 4u;
    uint8_t *out = dst + (size_t)y * (size_t)dw * 4u;
    for (int x = 0; x < dw; x++) {
      double fx = ((double)x + 0.5) * sx_scale - 0.5;
      int x0 = fx < 0.0 ? 0 : (int)fx;
      if (x0 >= sw) x0 = sw - 1;
      int x1 = x0 + 1 < sw ? x0 + 1 : sw - 1;
      double wx = (fx < 0.0 || fx >= (double)(sw - 1)) ? 0.0 : (fx - (double)x0);
      double wx0 = 1.0 - wx;
      const uint8_t *p00 = row0 + (size_t)x0 * 4u;
      const uint8_t *p10 = row0 + (size_t)x1 * 4u;
      const uint8_t *p01 = row1 + (size_t)x0 * 4u;
      const uint8_t *p11 = row1 + (size_t)x1 * 4u;
      double w00 = wx0 * wy0;
      double w10 = wx * wy0;
      double w01 = wx0 * wy;
      double w11 = wx * wy;
      int a = (int)lround(p00[3] * w00 + p10[3] * w10 + p01[3] * w01 + p11[3] * w11);
      if (a < 0) a = 0;
      if (a > 255) a = 255;
      for (int c = 0; c < 3; c++) {
        int v = (int)lround(p00[c] * w00 + p10[c] * w10 + p01[c] * w01 + p11[c] * w11);
        if (v < 0) v = 0;
        if (v > a) v = a;
        out[(size_t)x * 4u + (size_t)c] = (uint8_t)v;
      }
      out[(size_t)x * 4u + 3u] = (uint8_t)a;
    }
  }
}

#endif
