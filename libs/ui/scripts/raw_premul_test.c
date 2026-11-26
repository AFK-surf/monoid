// Unit tests for libs/ui/src/host/raw_premul.h (shared across Apple, Windows, and Linux hosts).
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "raw_premul.h"

static void put_le32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v & 0xFFu);
  p[1] = (uint8_t)((v >> 8) & 0xFFu);
  p[2] = (uint8_t)((v >> 16) & 0xFFu);
  p[3] = (uint8_t)((v >> 24) & 0xFFu);
}

static uint8_t *make_buf(uint32_t w, uint32_t h, size_t payload_len) {
  uint8_t *b = (uint8_t *)calloc(1, 16u + payload_len);
  assert(b != NULL);
  memcpy(b, "MBRAWPRE", 8u);
  put_le32(b + 8, w);
  put_le32(b + 12, h);
  return b;
}

int main(void) {
  int w = 0, h = 0;

  // Non-magic inputs
  const uint8_t png[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
  assert(!mb_raw_premul_is(NULL, 0));
  assert(!mb_raw_premul_is(png, sizeof(png)));
  assert(!mb_raw_premul_is((const uint8_t *)"MBRAWPR", 7));
  assert(mb_raw_premul_is((const uint8_t *)"MBRAWPRE", 8));

  // Valid 4x2 payload
  uint8_t *valid = make_buf(4, 2, 4u * 2u * 4u);
  assert(mb_raw_premul_parse(valid, 16u + 32u, &w, &h) == 1);
  assert(w == 4 && h == 2);
  free(valid);

  // Truncated header (< 16 bytes)
  const uint8_t trunc_hdr[12] = {'M', 'B', 'R', 'A', 'W', 'P', 'R', 'E', 1, 0, 0, 0};
  assert(mb_raw_premul_is(trunc_hdr, sizeof(trunc_hdr)) == 1);
  assert(mb_raw_premul_parse(trunc_hdr, sizeof(trunc_hdr), &w, &h) == 0);

  // Truncated pixel payload
  uint8_t *trunc_px = make_buf(2, 2, 12u);
  assert(mb_raw_premul_parse(trunc_px, 16u + 12u, &w, &h) == 0);
  free(trunc_px);

  // Zero dimensions
  uint8_t *z0 = make_buf(0, 4, 0);
  assert(mb_raw_premul_parse(z0, 16u, &w, &h) == 0);
  free(z0);
  uint8_t *z1 = make_buf(4, 0, 0);
  assert(mb_raw_premul_parse(z1, 16u, &w, &h) == 0);
  free(z1);

  // Exceeds 16384 limit
  uint8_t *over = make_buf(16385, 1, 16385u * 4u);
  assert(mb_raw_premul_parse(over, 16u + 16385u * 4u, &w, &h) == 0);
  free(over);

  // uint32 overflow: 65536 * 65536 * 4 wraps to 0 in 32-bit math
  uint8_t *ovf = make_buf(65536, 65536, 0);
  assert(mb_raw_premul_parse(ovf, 16u, &w, &h) == 0);
  free(ovf);

  // Trailing extra byte
  uint8_t *trail = make_buf(1, 1, 5u);
  assert(mb_raw_premul_parse(trail, 16u + 5u, &w, &h) == 0);
  free(trail);

  // Target size & device_max clamping
  int tw = 0, th = 0;
  mb_raw_premul_target_size(100, 300, 512, 16384, &tw, &th);
  assert(tw == 100 && th == 300);
  mb_raw_premul_target_size(1000, 3000, 512, 16384, &tw, &th);
  assert(tw == 171 && th == 512);
  mb_raw_premul_target_size(4096, 2048, 8192, 2048, &tw, &th);
  assert(tw == 2048 && th == 1024);
  mb_raw_premul_target_size(4096, 2048, 0, 2048, &tw, &th);
  assert(tw == 2048 && th == 1024);
  mb_raw_premul_target_size(1, 16000, 64, 16384, &tw, &th);
  assert(tw == 1 && th == 64);

  // Premultiplied downscale preserves constant premul color and clamps rgb <= a
  uint8_t src[8 * 4 * 4];
  for (int i = 0; i < 8 * 4; i++) {
    src[i * 4 + 0] = 100;
    src[i * 4 + 1] = 50;
    src[i * 4 + 2] = 25;
    src[i * 4 + 3] = 128;
  }
  uint8_t dst[4 * 2 * 4];
  mb_raw_premul_downscale(src, 8, 4, dst, 4, 2);
  for (int i = 0; i < 4 * 2; i++) {
    assert(dst[i * 4 + 0] == 100);
    assert(dst[i * 4 + 1] == 50);
    assert(dst[i * 4 + 2] == 25);
    assert(dst[i * 4 + 3] == 128);
  }

  // Non-uniform downscale: left half opaque red (255,0,0,255), right half semi-transparent blue (0,0,128,128)
  uint8_t src2[4 * 2 * 4];
  for (int y = 0; y < 2; y++) {
    for (int x = 0; x < 4; x++) {
      uint8_t *p = src2 + (y * 4 + x) * 4;
      if (x < 2) {
        p[0] = 255; p[1] = 0; p[2] = 0; p[3] = 255;
      } else {
        p[0] = 0; p[1] = 0; p[2] = 128; p[3] = 128;
      }
    }
  }
  // 4x2 -> 2x1 preserves left opaque red and right semi-transparent blue exactly
  uint8_t dst2[2 * 1 * 4];
  mb_raw_premul_downscale(src2, 4, 2, dst2, 2, 1);
  assert(dst2[0] == 255 && dst2[1] == 0 && dst2[2] == 0 && dst2[3] == 255);
  assert(dst2[4] == 0 && dst2[5] == 0 && dst2[6] == 128 && dst2[7] == 128);
  // 4x2 -> 1x1 averages left & right premultiplied channels: R~=128, G=0, B=64, A~=192, rgb<=a
  uint8_t dst1[4];
  mb_raw_premul_downscale(src2, 4, 2, dst1, 1, 1);
  assert(dst1[0] >= 127 && dst1[0] <= 128);
  assert(dst1[1] == 0);
  assert(dst1[2] == 64);
  assert(dst1[3] >= 191 && dst1[3] <= 192);
  assert(dst1[0] <= dst1[3] && dst1[1] <= dst1[3] && dst1[2] <= dst1[3]);

  printf("raw_premul_test: OK\n");
  return 0;
}
