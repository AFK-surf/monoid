// src/host/win_text.cpp unit tests on Windows:
//   cl.exe -nologo -EHsc -W3 -WX -D_CRT_SECURE_NO_WARNINGS -Isrc/host scripts/win_text_test.cpp \
//     -Foout/text/ -Feout/text/win_text_test.exe \
//     -link dwrite.lib d2d1.lib windowscodecs.lib user32.lib ole32.lib
//   out/text/win_text_test.exe
// Verifies:
// 1. fine_cover_from_sum / fine_downsample_nogrow matches original float rounding for all 0..4080 sums.
// 2. draw_fine with grow <= 0 allocates no float buffers, and with grow > 0 reuses Target::fine_a / fine_g.
// 3. drawn_ahead never blocks when drawing_mask has the requested phase set; marks skip_mask and worker frees safely.
// 4. mb_host_glyphs_ahead and rasterize preheat only 1 phase on first sight, and enqueue remaining phases only on a 2nd
//    distinct subpixel phase.
#define MB_NO_MOONBIT_H 1
#define MB_WIN_AHEAD_NO_THREADS 1
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef wchar_t *moonbit_string_t;
typedef uint8_t *moonbit_bytes_t;
static int32_t test_bytes_len = 0;
static int32_t test_doubles_len = 0;
static int32_t Moonbit_array_length(moonbit_string_t s) { return s ? (int32_t)wcslen(s) : 0; }
static int32_t Moonbit_array_length(moonbit_bytes_t) { return test_bytes_len; }
static int32_t Moonbit_array_length(double *) { return test_doubles_len; }
static moonbit_string_t moonbit_make_string_raw(int32_t len) {
  return (moonbit_string_t)calloc((size_t)(len > 0 ? len + 1 : 1), sizeof(wchar_t));
}

extern "C" {
int mb_atlas_size = 4096;
void mb_atlas_upload(int, int, int, int, const void *) {}
int mb_render_snapshot(const wchar_t *) { return 0; }
}

#include "win_text.cpp"

static int failed = 0;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      printf("%s:%d: failed: %s\n", __FILE__, __LINE__, #c);             \
      fflush(stdout);                                                    \
      failed = 1;                                                        \
    }                                                                    \
  } while (0)

static void test_fine_math_and_reuse(void) {
  // 1. Exhaustive 0..4080 equivalence between fine_cover_from_sum and original float formula.
  for (int sum = 0; sum <= 255 * FINE * FINE; sum++) {
    uint8_t got = fine_cover_from_sum(sum);
    float fsum = (float)sum / 255.0f;
    int fc = (int)(fsum * (255.0f / (FINE * FINE)) + 0.5f);
    uint8_t want = (uint8_t)(fc > 255 ? 255 : fc);
    CHECK(got == want);
  }

  // 2. fine_downsample_nogrow direct check on synthetic 4x4 fine BGRA blocks for all 0..4080 sums.
  uint8_t src[FINE * FINE * 4];
  uint8_t px[4];
  for (int sum = 0; sum <= 255 * FINE * FINE; sum++) {
    int rem = sum;
    for (int i = 0; i < FINE * FINE; i++) {
      int cover = rem > 255 ? 255 : rem;
      rem -= cover;
      uint8_t g = (uint8_t)(255 - cover);
      src[i * 4 + 0] = g;
      src[i * 4 + 1] = g;
      src[i * 4 + 2] = g;
      src[i * 4 + 3] = 255;
    }
    fine_downsample_nogrow(src, FINE * 4, 1, 1, px);
    uint8_t want = fine_cover_from_sum(sum);
    CHECK(px[0] == want && px[1] == want && px[2] == want && px[3] == want);
  }

  // 3. Real DirectWrite draw_fine with grow == 0 (no float buffers allocated) and grow > 0 (reused buffers).
  init();
  CHECK(dw != NULL && d2d != NULL && wic != NULL);
  if (!dw || !d2d || !wic) return;
  text_scale = 2.0;
  wchar_t sH[] = L"H";
  int k = mb_host_text_key(sH, 16.0, 400, 0);
  CHECK(k >= 0);
  IDWriteTextLayout *l = main_layout_for(k);
  CHECK(l != NULL);
  ClusterBounds cb = {};
  measure_bounds(l, &cb);
  int pw = 24, ph = 32;
  uint8_t *out = (uint8_t *)calloc((size_t)pw * ph, 4);
  CHECK(main_target.fine_a == NULL && main_target.fine_g == NULL && main_target.fine_cap == 0);
  CHECK(draw_fine(l, 2.0, cb.x0, cb.y0, 0.0, pw, ph, 0.0, &main_target, out));
  CHECK(main_target.fine_a == NULL && main_target.fine_g == NULL && main_target.fine_cap == 0);
  int nonzero = 0;
  for (int i = 0; i < pw * ph; i++) {
    if (out[i * 4 + 3] > 0) nonzero++;
  }
  CHECK(nonzero > 0);

  // Now with grow > 0: allocates once, then reuses the exact same pointers for same/smaller dimensions.
  CHECK(draw_fine(l, 2.0, cb.x0, cb.y0, 0.0, pw, ph, 0.5, &main_target, out));
  float *pa = main_target.fine_a;
  float *pg = main_target.fine_g;
  size_t pcap = main_target.fine_cap;
  CHECK(pa != NULL && pg != NULL && pcap >= (size_t)(pw * FINE) * (size_t)(ph * FINE));
  CHECK(draw_fine(l, 2.0, cb.x0, cb.y0, 0.0, pw - 2, ph - 2, 0.5, &main_target, out));
  CHECK(main_target.fine_a == pa && main_target.fine_g == pg && main_target.fine_cap == pcap);
  free(out);
}

static void test_ahead_single_phase_and_nonblocking(void) {
  ahead_forget();
  text_scale = 2.0;
  wchar_t sA[] = L"A";
  int k1 = mb_host_text_key(sA, 16.0, 400, 0);
  CHECK(k1 >= 0);

  // 1. First mb_host_glyphs_ahead queues ONLY the requested phase (sub = 0), nothing in ahead_rest.
  int32_t keys1[1] = {k1 | (0 << 26)};
  mb_host_glyphs_ahead(keys1, 1);
  CHECK(entries[k1].subs_queued == 0x01);
  Ahead *a1 = k1 < ahead_of_cap ? ahead_of[k1] : NULL;
  CHECK(a1 != NULL);
  if (!a1) return;
  CHECK(a1->want_mask == 0x01);
  CHECK(a1->first_mask == 0x01);
  CHECK(ahead_first.n == 1);
  CHECK(ahead_rest.n == 0);

  // 2. Requesting the same phase again still does NOT enqueue phases 1..3.
  mb_host_glyphs_ahead(keys1, 1);
  CHECK(entries[k1].subs_queued == 0x01);
  CHECK(a1->want_mask == 0x01);
  CHECK(ahead_rest.n == 0);

  // 3. Requesting a 2nd distinct phase (sub = 2) enqueues remaining phases {1, 2, 3}, with sub = 2 in first_mask.
  int32_t keys2[1] = {k1 | (2 << 26)};
  mb_host_glyphs_ahead(keys2, 1);
  CHECK(entries[k1].subs_queued == 0x0F);
  CHECK(a1->want_mask == 0x0F);
  CHECK(a1->first_mask == (uint8_t)((1 << 0) | (1 << 2)));
  CHECK(ahead_first.n == 2);
  CHECK(ahead_rest.n == 1);

  // 4. drawn_ahead when drawing_mask has bit 0 set: MUST return false immediately (no block!), mark skip_mask |= 1.
  EnterCriticalSection(&ahead_lock);
  a1->want_mask &= (uint8_t)~0x01;
  a1->first_mask &= (uint8_t)~0x01;
  a1->drawing_mask |= 0x01;
  LeaveCriticalSection(&ahead_lock);

  Drawn d = {};
  CHECK(!drawn_ahead(k1, 0, &d));
  CHECK(d.px == NULL);
  CHECK(ahead_of[k1] == a1);
  EnterCriticalSection(&ahead_lock);
  CHECK((a1->skip_mask & 0x01) != 0);
  CHECK((a1->drawing_mask & 0x01) != 0);
  LeaveCriticalSection(&ahead_lock);

  // Simulate worker finishing phase 0: must discard and free d.px without setting have_mask.
  Drawn worker_d = {};
  worker_d.pw = 4;
  worker_d.ph = 4;
  worker_d.px = (uint8_t *)malloc(4 * 4 * 4);
  ahead_finish_phase(a1, 0, true, worker_d);
  EnterCriticalSection(&ahead_lock);
  CHECK((a1->drawing_mask & 0x01) == 0);
  CHECK((a1->skip_mask & 0x01) == 0);
  CHECK((a1->have_mask & 0x01) == 0);
  CHECK(a1->drawn[0].px == NULL);
  LeaveCriticalSection(&ahead_lock);

  // 5. rasterize() on a fresh glyph at phase 1: draws phase 1 and does NOT enqueue other phases.
  int rest_before = ahead_rest.n;
  wchar_t sB[] = L"B";
  int k2 = mb_host_text_key(sB, 16.0, 400, 0);
  CHECK(k2 >= 0);
  rasterize(k2 | (1 << 26));
  CHECK(entries[k2].subs_queued == (1 << 1));
  CHECK(k2 >= ahead_of_cap || ahead_of[k2] == NULL);
  CHECK(ahead_rest.n == rest_before);

  // 6. rasterize() on the same glyph at a 2nd distinct phase (phase 3): enqueues remaining {0, 2} into ahead_rest.
  rasterize(k2 | (3 << 26));
  CHECK(entries[k2].subs_queued == 0x0F);
  Ahead *a2 = k2 < ahead_of_cap ? ahead_of[k2] : NULL;
  CHECK(a2 != NULL);
  if (a2) {
    CHECK(a2->want_mask == (uint8_t)((1 << 0) | (1 << 2)));
    CHECK(a2->first_mask == 0);
  }
  CHECK(ahead_rest.n == rest_before + 1);

  ahead_forget();
  free(held_px);
  held_px = NULL;
  held_key = -1;
}

int main(void) {
  test_fine_math_and_reuse();
  test_ahead_single_phase_and_nonblocking();
  if (failed) return 1;
  printf("win_text: ok\n");
  return 0;
}
