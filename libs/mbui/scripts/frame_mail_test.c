// src/host/frame_mail.h's tests (the frame waiting between Android's app thread and its GL thread), but for fm_keep,
// which scripts/gles_render_test.c tests in GL: the pool's three buffers go round, none made once they do; a frame
// taking another's place says what both said differs, all of it where either said all, told nothing, or was laid out at
// another size; a frame let go undrawn leaves the next drawn whole.
//   cc -Wall -I src/host scripts/frame_mail_test.c -lm -o out/frame_mail_test && out/frame_mail_test
#include <stdio.h>
#include "frame_mail.h"

static int failed;

#define CHECK(c)                                                      \
  do {                                                                \
    if (!(c)) {                                                       \
      fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #c); \
      failed = 1;                                                     \
    }                                                                 \
  } while (0)

// the drawing thread's kept frame (gles_render.h's fbuf), given back as the next is taken, as fm_keep does
static float *kept;
static size_t kept_cap;

static int take(handed_frame *got) {
  if (!fm_take(got)) return 0;
  fm_pool_give(kept, kept_cap);
  kept = got->f;
  kept_cap = got->cap;
  return 1;
}

// a frame of `count` instances made at w × h (2 pixels a point), its floats written (as mb_groups_floats would)
static void make(int32_t count, double w, double h) {
  size_t need = (size_t)count * 32 + 64;
  float *f = fm_present(need, count, 0.1, 0.2, 0.3, w, h, 2);
  for (size_t i = 0; i < need; i++) f[i] = (float)count;
}

static int rect_is(const said_parts *s, int i, double x, double y, double w, double h) {
  return i < s->n && s->r[i][0] == x && s->r[i][1] == y && s->r[i][2] == w && s->r[i][3] == h;
}

int main(void) {
  handed_frame got;

  // Nothing handed over: nothing to take.
  CHECK(!fm_publish());
  CHECK(!fm_take(&got));

  // A frame made, handed over and taken: its floats, its size, what it said differs.
  fm_said(10, 10, 20, 20);
  make(3, 100, 75);
  CHECK(fm_publish());
  CHECK(take(&got));
  CHECK(got.count == 3 && got.w == 100 && got.h == 75 && got.scale == 2);
  CHECK(got.f[0] == 3);
  CHECK(got.said.told == 1 && got.said.whole == 0 && got.said.n == 1);
  CHECK(rect_is(&got.said, 0, 10, 10, 20, 20));
  CHECK(!fm_take(&got));

  // The pool's buffers go round, the GL thread taking each frame or one in two (the other merged): three made at most,
  // and none after they go round.
  for (int i = 0; i < 6; i++) {
    make(4, 100, 75);
    CHECK(fm_publish());
    if (i % 2) CHECK(take(&got));
  }
  int made = fm_pool_made;
  CHECK(made == 3);
  for (int i = 0; i < 200; i++) {
    make(4, 100, 75);
    CHECK(fm_publish());
    if (i % 3) CHECK(take(&got));
  }
  take(&got);
  CHECK(fm_pool_made == made);

  // Two frames handed over, the first not taken: the second taken in its place, what both said differs (its own
  // first, then the other's).
  fm_said(1, 2, 3, 4);
  make(2, 100, 75);
  CHECK(fm_publish());
  fm_said(5, 6, 7, 8);
  make(2, 100, 75);
  CHECK(fm_publish());
  CHECK(take(&got));
  CHECK(got.said.told == 1 && got.said.whole == 0 && got.said.n == 2);
  CHECK(rect_is(&got.said, 0, 5, 6, 7, 8));
  CHECK(rect_is(&got.said, 1, 1, 2, 3, 4));
  CHECK(!fm_take(&got));

  // Presented twice in one frame (the second in the first's place): both said.
  fm_said(1, 1, 1, 1);
  make(2, 100, 75);
  fm_said(2, 2, 2, 2);
  make(2, 100, 75);
  CHECK(fm_publish());
  CHECK(take(&got));
  CHECK(got.said.n == 2 && got.said.whole == 0);
  CHECK(rect_is(&got.said, 0, 2, 2, 2, 2));
  CHECK(rect_is(&got.said, 1, 1, 1, 1, 1));

  // Laid out at another size than the frame it takes the place of: all of it.
  fm_said(1, 1, 1, 1);
  make(2, 100, 75);
  CHECK(fm_publish());
  fm_said(2, 2, 2, 2);
  make(2, 120, 75);
  CHECK(fm_publish());
  CHECK(take(&got));
  CHECK(got.said.told == 1 && got.said.whole == 1);
  fm_said(1, 1, 1, 1);
  make(2, 120, 75);
  CHECK(fm_publish());
  fm_said(1, 1, 1, 1);
  make(2, 120, 75);
  fm_said(2, 2, 2, 2);
  CHECK(fm_present(10, 2, 0, 0, 0, 120, 75, 3) != NULL);  // (presented again in the frame: at another scale)
  CHECK(fm_publish());
  CHECK(take(&got));
  CHECK(got.said.whole == 1);

  // One that told nothing (drawn whole), and one taking its place that said a part: all of it. And the other way.
  make(2, 120, 75);
  CHECK(fm_publish());
  fm_said(2, 2, 2, 2);
  make(2, 120, 75);
  CHECK(fm_publish());
  CHECK(take(&got));
  CHECK(got.said.told == 1 && got.said.whole == 1);
  fm_said(2, 2, 2, 2);
  make(2, 120, 75);
  CHECK(fm_publish());
  make(2, 120, 75);
  CHECK(fm_publish());
  CHECK(take(&got));
  CHECK(got.said.told == 0);
  // (and one that said all of it, a part said by the next)
  fm_said(0, 0, -1, -1);
  make(2, 120, 75);
  CHECK(fm_publish());
  fm_said(2, 2, 2, 2);
  make(2, 120, 75);
  CHECK(fm_publish());
  CHECK(take(&got));
  CHECK(got.said.whole == 1);

  // More parts than it keeps: the last grown round the rest.
  for (int i = 0; i < MB_PARTS + 2; i++) fm_said(i * 10, 0, 5, 5);
  make(2, 120, 75);
  CHECK(fm_publish());
  CHECK(take(&got));
  CHECK(got.said.n == MB_PARTS && got.said.whole == 0);
  CHECK(rect_is(&got.said, MB_PARTS - 1, (MB_PARTS - 1) * 10, 0, 25, 5));

  // A frame pending let go undrawn (made for a GL context gone): nothing to take, and the next handed over, though it
  // says a part, drawn whole; the one after it as it says.
  fm_said(2, 2, 2, 2);
  make(2, 120, 75);
  CHECK(fm_publish());
  fm_drop_pending();
  CHECK(!fm_take(&got));
  fm_said(3, 3, 3, 3);
  make(2, 120, 75);
  CHECK(fm_publish());
  CHECK(take(&got));
  CHECK(got.said.told == 1 && got.said.whole == 1);
  fm_said(3, 3, 3, 3);
  make(2, 120, 75);
  CHECK(fm_publish());
  CHECK(take(&got));
  CHECK(got.said.whole == 0 && got.said.n == 1);
  if (fm_pool_made != made) fprintf(stderr, "buffers made: %d, then %d\n", made, fm_pool_made);
  CHECK(fm_pool_made == made);

  if (failed) return 1;
  printf("frame_mail_test: ok\n");
  return 0;
}
