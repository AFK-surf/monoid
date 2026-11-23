// The frame waiting between the thread that makes frames and the one that draws them (Android's: MBView's app thread
// and GL thread, android_host.c). The app's thread makes a frame (fm_present: a buffer of the pool for its floats; the
// size it was laid out at; what of it was said to differ, fm_said) as `fm_made`, handed over as the frame ends
// (fm_publish) as the one `fm_pending`; the drawing thread takes the newest pending as it draws (fm_take: its floats
// the renderer's kept frame, fm_keep), the buffer it held given back to the pool. A frame handed over while the one
// before still waits takes its place, what both said to differ joined (all of it where either was drawn whole, or the
// two were laid out at different sizes): the newest drawn, never a queue of old ones behind it. A frame pending let go
// undrawn (fm_drop_pending: made for a context gone) leaves the next drawn whole. The caller holds one lock round
// fm_publish, fm_take and fm_drop_pending (MBView's `mail`); the pool has its own.
//
// Taken to be shown (fm_keep, `shown`), what the frame said differs is what the renderer draws it by. Taken for a read
// back only (MBView.glSync: the app waits on a pixel of it), it is never shown on the surface: what it said differs is
// not what the next frame drawn is to go by, and the renderer's canvas no longer holds the frame before the next (so
// the next is drawn whole into it, whatever it says).
//
// Plain C (pthreads), no GL but fm_keep, which is the renderer's (gles_render.h, included before this for it):
// scripts/frame_mail_test.c tests the rest, scripts/gles_render_test.c fm_keep.
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifndef MB_PARTS
#define MB_PARTS 8
#endif

typedef struct {
  int told, whole, n;
  double r[MB_PARTS][4];
} said_parts;

typedef struct {
  float *f;
  size_t cap;
  int32_t count;
  double r, g, b, w, h, scale;
  said_parts said;
  int has;
} handed_frame;

static handed_frame fm_made, fm_pending;
// what the app said differs of the frame being made (the app's thread)
static said_parts fm_said_now;
// a frame pending was let go undrawn: the next handed over is drawn whole
static int fm_dropped;

#define MB_POOL 3
static pthread_mutex_t fm_pool_mu = PTHREAD_MUTEX_INITIALIZER;
static float *fm_pool_f[MB_POOL];
static size_t fm_pool_cap[MB_POOL];
// how many buffers the pool had to make (none once its three go round: the one made, the one pending, the one drawn)
static int fm_pool_made;

// A buffer of at least `need` floats (its room in *cap), from the pool where it has one.
static float *fm_pool_take(size_t need, size_t *cap) {
  float *got = NULL;
  size_t got_cap = 0;
  pthread_mutex_lock(&fm_pool_mu);
  for (int i = 0; i < MB_POOL; i++)
    if (fm_pool_f[i] && fm_pool_cap[i] >= need) {
      got = fm_pool_f[i];
      got_cap = fm_pool_cap[i];
      fm_pool_f[i] = NULL;
      break;
    }
  pthread_mutex_unlock(&fm_pool_mu);
  if (!got) {
    got_cap = need + need / 4;
    got = malloc(got_cap * sizeof(float));
    fm_pool_made++;
  }
  *cap = got_cap;
  return got;
}

static void fm_pool_give(float *f, size_t cap) {
  if (!f) return;
  pthread_mutex_lock(&fm_pool_mu);
  for (int i = 0; i < MB_POOL; i++)
    if (!fm_pool_f[i]) {
      fm_pool_f[i] = f;
      fm_pool_cap[i] = cap;
      f = NULL;
      break;
    }
  pthread_mutex_unlock(&fm_pool_mu);
  free(f);
}

static void said_add(said_parts *d, double x, double y, double w, double h) {
  d->told = 1;
  if (w < 0 || h < 0) {
    d->whole = 1;
  } else if (w > 0 && h > 0) {
    // (more than it keeps: the last one grown round it)
    if (d->n == MB_PARTS) {
      double *e = d->r[MB_PARTS - 1];
      double x1 = fmax(e[0] + e[2], x + w), y1 = fmax(e[1] + e[3], y + h);
      e[0] = fmin(e[0], x);
      e[1] = fmin(e[1], y);
      e[2] = x1 - e[0];
      e[3] = y1 - e[1];
    } else {
      double *e = d->r[d->n++];
      e[0] = x;
      e[1] = y;
      e[2] = w;
      e[3] = h;
    }
  }
}

// What frame `d` said differs joined with what the one it takes the place of (`was`, never drawn) said.
static void said_join(said_parts *d, const said_parts *was) {
  if (!d->told || d->whole) return;
  if (!was->told || was->whole) {
    d->whole = 1;
    return;
  }
  for (int i = 0; i < was->n; i++) said_add(d, was->r[i][0], was->r[i][1], was->r[i][2], was->r[i][3]);
}

// (the app's thread) a part of the frame being made said to differ (w or h below 0: all of it)
static void fm_said(double x, double y, double w, double h) { said_add(&fm_said_now, x, y, w, h); }

// (the app's thread) a frame of `count` instances made, laid out at w × h points, `scale` pixels a point: the buffer
// of at least `need` floats its instances are drawn out into (presented twice in one frame: the second in the first's
// place, both said).
static float *fm_present(size_t need, int32_t count, double r, double g, double b, double w, double h, double scale) {
  if (fm_made.has) {
    said_parts was = fm_made.said;
    fm_made.said = fm_said_now;
    said_join(&fm_made.said, &was);
  } else {
    fm_made.said = fm_said_now;
  }
  fm_said_now = (said_parts){0};
  if (fm_made.cap < need) {
    fm_pool_give(fm_made.f, fm_made.cap);
    fm_made.f = fm_pool_take(need, &fm_made.cap);
  }
  fm_made.count = count;
  fm_made.r = r;
  fm_made.g = g;
  fm_made.b = b;
  fm_made.w = w;
  fm_made.h = h;
  fm_made.scale = scale;
  fm_made.has = 1;
  return fm_made.f;
}

// (the app's thread, under the lock, as a frame ends) the frame made handed over: whether there was one
static int fm_publish(void) {
  if (!fm_made.has) return 0;
  if (fm_pending.has) {
    said_join(&fm_made.said, &fm_pending.said);
    if (fm_pending.w != fm_made.w || fm_pending.h != fm_made.h || fm_pending.scale != fm_made.scale)
      fm_made.said.whole = fm_made.said.told = 1;
  }
  if (fm_dropped) {
    fm_made.said.whole = fm_made.said.told = 1;
    fm_dropped = 0;
  }
  // (the pending one's buffer, never drawn, the next made's)
  float *f = fm_pending.f;
  size_t cap = fm_pending.cap;
  fm_pending = fm_made;
  fm_made = (handed_frame){0};
  fm_made.f = f;
  fm_made.cap = cap;
  return 1;
}

// (the drawing thread, under the lock) the frame pending taken into *got (its buffer the taker's, to give back to the
// pool once it is done with it): whether there was one
static int fm_take(handed_frame *got) {
  if (!fm_pending.has) return 0;
  *got = fm_pending;
  fm_pending = (handed_frame){0};
  return 1;
}

// (under the lock) the frame pending let go undrawn: the next handed over drawn whole
static void fm_drop_pending(void) {
  if (!fm_pending.has) return;
  fm_pool_give(fm_pending.f, fm_pending.cap);
  fm_pending = (handed_frame){0};
  fm_dropped = 1;
}

#ifdef MB_GLES_RENDER
// (the drawing thread, its context current) the frame taken made the renderer's kept one (fbuf: drawn by
// gl_present_kept, again by draw_kept), the buffer it held given back. `shown` 0: taken for a read back, never shown
// (above).
static void fm_keep(handed_frame *got, int shown) {
  float *was = fbuf;
  size_t was_cap = fcap;
  fbuf = got->f;
  fcap = got->cap;
  kept_count = got->count;
  kept_r = got->r;
  kept_g = got->g;
  kept_b = got->b;
  cur_w = got->w;
  cur_h = got->h;
  cur_scale = got->scale;
  if (shown) {
    dirty_told = got->said.told;
    dirty_whole = got->said.whole;
    dirty_n = got->said.n;
    memcpy(dirty, got->said.r, sizeof dirty);
  } else {
    dirty_told = dirty_whole = dirty_n = 0;
    if (!offscreen) canvas_ok = 0;
  }
  fm_pool_give(was, was_cap);
}
#endif
