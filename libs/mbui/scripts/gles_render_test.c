// src/host/gles_render.h's tests on the window's way (not mbui-render's offscreen one: Android's surface, Linux's
// window), in OpenGL ES 3 on EGL's surfaceless platform (Mesa's llvmpipe where there is no GPU), a framebuffer of the
// test's own standing for the surface (target_fb): a frame drawn whole goes straight onto it, no canvas made; one said
// to differ in parts is drawn into the canvas and shown, the surface then the same to the byte as the frame drawn
// whole; the blur under glass kept while what is under it is the same, made again once it is not, never kept while a
// picture under it had no texture yet; a group the host keeps drawn out to the float the app's own instance would be;
// a frame handed over from another thread (frame_mail.h) taken only to read back leaving the next drawn whole; three
// groups of glass on one screen each keeping its own blur, made again only for the one something moved under.
//   cc -Wall -Wno-unused-function -I src/host -I "$MOON_HOME/include" scripts/gles_render_test.c
//     $(pkg-config --cflags --libs epoxy zlib) -lm -o out/gles_render_test && out/gles_render_test
#include <epoxy/gl.h>
#include <epoxy/egl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#include "moonbit.h"
#include "corner_sl.h"

#define LOG(...) (fprintf(stderr, "gles_render_test: " __VA_ARGS__), fputc('\n', stderr))
#define MB_STREAM_TEX 4194304
#define MB_VIEW_TEX 8388608

// picture 1's texture: none (not decoded yet) till a test makes one
static GLuint picture_one;
static GLuint image_tex(int id) { return id == 1 ? picture_one : 0; }
static void view_parts_in(int tid, int32_t start, int32_t end) { (void)tid, (void)start, (void)end; }

#include "gles_render.h"
#include "frame_mail.h"

static int failed;

#define CHECK(c)                                                      \
  do {                                                                \
    if (!(c)) {                                                       \
      fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #c); \
      failed = 1;                                                     \
    }                                                                 \
  } while (0)

// the surface: 100 × 75 points, 2 pixels a point
#define W 100
#define H 75
#define S 2

// An instance: a rect at x, y, w × h of colour (r, g, b), kind `kind`, image `tid`, its clip the window's.
static void rect_at(double *d, double x, double y, double w, double h, int kind, double r, double g, double b,
                    double tid) {
  memset(d, 0, MB_INST * sizeof(double));
  d[0] = x;
  d[1] = y;
  d[2] = w;
  d[3] = h;
  d[5] = kind;
  d[8] = r;
  d[9] = g;
  d[10] = b;
  d[11] = 1;
  d[18] = W;
  d[19] = H;
  d[20] = tid;
}

// What framebuffer `fb` holds (fb_w × fb_h, RGBA): the caller frees it.
static unsigned char *pixels_of_fb(GLuint fb) {
  unsigned char *px = malloc((size_t)fb_w * fb_h * 4);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, fb);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, fb_w, fb_h, GL_RGBA, GL_UNSIGNED_BYTE, px);
  return px;
}

// The surface the same to the byte as the frame kept drawn whole again (draw_kept_read, as drawn_pixels reads it).
// (the blurs kept by glass shown again there as they are: surface_as_fresh makes them anew)
static int surface_as_whole(GLuint surface) {
  unsigned char *shown = pixels_of_fb(surface);
  draw_kept_read();
  unsigned char *whole = pixels_of_fb(read_fb);
  glBindFramebuffer(GL_FRAMEBUFFER, surface);
  int same = memcmp(shown, whole, (size_t)fb_w * fb_h * 4) == 0;
  free(shown);
  free(whole);
  return same;
}

// The surface the same to the byte as the frame kept drawn whole again with no blur kept, each made anew.
static int surface_as_fresh(GLuint surface) {
  glass_forget();
  return surface_as_whole(surface);
}

// A frame handed over from the thread that makes it (frame_mail.h: Android's app thread), what it says differs a
// part x, y, w × h of it.
static void hand(const double *inst, int32_t count, double x, double y, double w, double h) {
  // (said as it is painted, before it is presented: mb_host_render_dirty)
  fm_said(x, y, w, h);
  float *f = fm_present(gl_frame_floats(count), count, 0.1, 0.2, 0.3, W, H, S);
  mb_groups_floats(f, inst, count);
  CHECK(fm_publish());
}

// The frame handed over taken (Android's Native.take): to be drawn (and drawn, Native.draw), or only read back.
static void take(int shown) {
  handed_frame got;
  CHECK(fm_take(&got));
  fm_keep(&got, shown);
  if (shown) gl_present_kept(kept_count, kept_r, kept_g, kept_b);
}

int main(void) {
  EGLDisplay d = eglGetPlatformDisplayEXT(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
  if (d == EGL_NO_DISPLAY || !eglInitialize(d, NULL, NULL)) {
    LOG("no EGL display (surfaceless)");
    return 1;
  }
  eglBindAPI(EGL_OPENGL_ES_API);
  static const EGLint want[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE};
  EGLConfig cfg = NULL;
  EGLint n = 0;
  eglChooseConfig(d, want, &cfg, 1, &n);
  static const EGLint attrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE};
  EGLContext ctx = eglCreateContext(d, n > 0 ? cfg : EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attrs);
  if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
    LOG("no OpenGL ES 3 context");
    return 1;
  }
  gl_setup();
  // the surface: a framebuffer of the test's, drawn into as the window's is (offscreen 0)
  fb_w = W * S;
  fb_h = H * S;
  cur_w = W;
  cur_h = H;
  cur_scale = S;
  GLuint surface_tex, surface;
  glGenTextures(1, &surface_tex);
  glBindTexture(GL_TEXTURE_2D, surface_tex);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
  glGenFramebuffers(1, &surface);
  glBindFramebuffer(GL_FRAMEBUFFER, surface);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, surface_tex, 0);
  CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
  target_fb = surface;
  CHECK(offscreen == 0);

  // A frame drawn whole goes straight onto the surface: no canvas made, none holding a frame.
  double two[2 * MB_INST];
  rect_at(two, 10, 10, 20, 20, 0, 0.9, 0.2, 0.1, 0);
  rect_at(two + MB_INST, 60, 40, 20, 20, 0, 0.1, 0.8, 0.3, 0);
  gl_present(two, 2, 0.1, 0.2, 0.3);
  CHECK(canvas_fb == 0);
  CHECK(canvas_ok == 0);
  CHECK(surface_as_whole(surface));

  // One said to differ in a part: the canvas made, drawn whole into it first (it held no frame), then shown; the next
  // drawn in its parts alone. The surface each time the same to the byte as the frame drawn whole.
  two[0] = 12;
  mb_host_render_dirty(8, 8, 26, 24);
  gl_present(two, 2, 0.1, 0.2, 0.3);
  CHECK(canvas_fb != 0);
  CHECK(canvas_ok == 1);
  CHECK(surface_as_whole(surface));
  two[0] = 14;
  two[MB_INST + 1] = 44;
  mb_host_render_dirty(10, 8, 26, 24);
  mb_host_render_dirty(58, 38, 24, 28);
  gl_present(two, 2, 0.1, 0.2, 0.3);
  CHECK(canvas_ok == 1);
  CHECK(surface_as_whole(surface));
  // (and one whole again after: straight onto the surface, the canvas left holding no frame)
  two[0] = 16;
  gl_present(two, 2, 0.1, 0.2, 0.3);
  CHECK(canvas_ok == 0);
  CHECK(surface_as_whole(surface));

  // Frames handed over from another thread (frame_mail.h, Android's two), drawn in their parts as they say. One taken
  // only to read back (Android's glSync, the app waiting on a pixel of it) is never on the surface: what it said differs
  // is not what the next drawn goes by, nor is anything left of it there, and the canvas no longer holds the frame
  // before. So the next drawn, which says only its own part, is drawn whole into the canvas: the surface then is what it
  // is drawn whole, the part the one read back changed too. So too where the one read back is drawn again first
  // (Native.redraw: a native view's picture changed).
  hand(two, 2, 10, 8, 30, 30);
  take(1);
  CHECK(surface_as_whole(surface));
  two[MB_INST + 1] = 46;
  hand(two, 2, 58, 38, 24, 30);
  take(1);
  CHECK(canvas_ok == 1);
  CHECK(surface_as_whole(surface));
  two[0] = 20;
  hand(two, 2, 10, 8, 32, 24);
  take(0);
  draw_kept_read();
  glBindFramebuffer(GL_FRAMEBUFFER, surface);
  CHECK(canvas_ok == 0);
  CHECK(dirty_told == 0 && dirty_whole == 0 && dirty_n == 0);
  two[MB_INST + 1] = 40;
  hand(two, 2, 58, 38, 24, 30);
  take(1);
  CHECK(surface_as_whole(surface));
  two[0] = 24;
  hand(two, 2, 18, 8, 28, 24);
  take(0);
  draw_kept_read();
  draw_kept();
  CHECK(dirty_told == 0);
  two[MB_INST + 1] = 44;
  hand(two, 2, 58, 38, 24, 30);
  take(1);
  CHECK(surface_as_whole(surface));
  // (and the canvas holds the frame again: the one after drawn in its parts alone, the same)
  two[MB_INST + 1] = 42;
  hand(two, 2, 58, 38, 24, 30);
  take(1);
  CHECK(canvas_ok == 1);
  CHECK(surface_as_whole(surface));

  // The blur under glass kept while what is drawn under it is the same: what is over it changing makes none again;
  // what is under it changing does.
  double g3[3 * MB_INST];
  rect_at(g3, 10, 10, 60, 40, 0, 0.9, 0.1, 0.1, 0);
  rect_at(g3 + MB_INST, 20, 20, 40, 30, 5, 1, 1, 1, -2);
  g3[MB_INST + 7] = 6;
  g3[MB_INST + 11] = 0.5;
  rect_at(g3 + 2 * MB_INST, 80, 60, 10, 10, 0, 0.1, 0.1, 0.9, 0);
  int made = blurs_made;
  gl_present(g3, 3, 0.1, 0.2, 0.3);
  CHECK(blurs_made == made + 1);
  CHECK(kept_ok == 1);
  g3[2 * MB_INST + 0] = 84;  // over the glass: moved
  gl_present(g3, 3, 0.1, 0.2, 0.3);
  CHECK(blurs_made == made + 1);
  CHECK(kept_ok == 1);
  g3[0] = 12;  // under it: moved
  gl_present(g3, 3, 0.1, 0.2, 0.3);
  CHECK(blurs_made == made + 2);
  CHECK(kept_ok == 1);

  // A picture under it with no texture yet (drawn without it): that blur is not kept as what is under it; once the
  // picture has its texture, it is made and kept.
  double p3[3 * MB_INST];
  memcpy(p3, g3, sizeof p3);
  rect_at(p3, 10, 10, 60, 40, 4, 1, 1, 1, 1);
  p3[12] = 0;
  p3[13] = 0;
  p3[14] = 1;
  p3[15] = 1;
  gl_present(p3, 3, 0.1, 0.2, 0.3);
  CHECK(kept_ok == 0);
  CHECK(pictures_missing == 1);
  static const unsigned char px[16] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255};
  glGenTextures(1, &picture_one);
  glBindTexture(GL_TEXTURE_2D, picture_one);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  made = blurs_made;
  p3[2 * MB_INST + 0] = 86;
  gl_present(p3, 3, 0.1, 0.2, 0.3);
  CHECK(blurs_made == made + 1);
  CHECK(kept_ok == 1);
  CHECK(pictures_missing == 0);

  // Three groups of glass on one screen (frosted at the top, liquid in the middle, frosted at the foot, each with
  // something of its own under it, a caret over all): each keeps its own blur. A frame where only what is over them
  // moves makes none; one where something moves under the middle one alone makes that one's again, the others kept.
  // The surface each time the same to the byte as the frame drawn whole with every blur made anew.
  double s3[8 * MB_INST];
  rect_at(s3, 0, 0, W, H, 0, 0.95, 0.95, 0.9, 0);
  rect_at(s3 + 1 * MB_INST, 8, 4, 26, 8, 0, 0.9, 0.1, 0.1, 0);
  rect_at(s3 + 2 * MB_INST, 5, 2, 36, 10, 5, 1, 1, 1, -2);
  s3[2 * MB_INST + 7] = 2;
  s3[2 * MB_INST + 11] = 0.5;
  rect_at(s3 + 3 * MB_INST, 62, 32, 20, 8, 0, 0.1, 0.7, 0.2, 0);
  rect_at(s3 + 4 * MB_INST, 60, 30, 30, 12, 6, 1, 1, 1, -3);
  s3[4 * MB_INST + 4] = 6;
  s3[4 * MB_INST + 7] = 2;
  s3[4 * MB_INST + 11] = 0.3;
  s3[4 * MB_INST + 21] = 2;
  s3[4 * MB_INST + 23] = 1;
  rect_at(s3 + 5 * MB_INST, 10, 60, 25, 6, 0, 0.2, 0.2, 0.9, 0);
  rect_at(s3 + 6 * MB_INST, 5, 57, 40, 12, 5, 1, 1, 1, -4);
  s3[6 * MB_INST + 7] = 2;
  s3[6 * MB_INST + 11] = 0.5;
  rect_at(s3 + 7 * MB_INST, 90, 65, 2, 6, 0, 0, 0, 0, 0);
  made = blurs_made;
  gl_present(s3, 8, 0.1, 0.2, 0.3);
  LOG("three groups, first frame: %d blurs", blurs_made - made);
  CHECK(blurs_made == made + 3);
  CHECK(surface_as_fresh(surface));
  for (int i = 0; i < 3; i++) {
    s3[7 * MB_INST + 1] = 62 + i;  // the caret: moved
    made = blurs_made;
    gl_present(s3, 8, 0.1, 0.2, 0.3);
    LOG("three groups, the caret moved: %d blurs", blurs_made - made);
    CHECK(blurs_made == made);
    CHECK(kept_ok == 1);
    CHECK(surface_as_fresh(surface));
  }
  s3[3 * MB_INST + 0] = 64;  // under the liquid glass alone: moved
  made = blurs_made;
  gl_present(s3, 8, 0.1, 0.2, 0.3);
  LOG("three groups, what is under the middle one moved: %d blurs", blurs_made - made);
  CHECK(blurs_made == made + 1);
  CHECK(surface_as_fresh(surface));
  s3[7 * MB_INST + 1] = 60;
  made = blurs_made;
  gl_present(s3, 8, 0.1, 0.2, 0.3);
  CHECK(blurs_made == made);
  CHECK(surface_as_fresh(surface));
  s3[1 * MB_INST + 0] = 9;  // under the top one: moved, that one's alone made again
  made = blurs_made;
  gl_present(s3, 8, 0.1, 0.2, 0.3);
  CHECK(blurs_made == made + 1);
  CHECK(surface_as_fresh(surface));

  // Fourteen independent glass groups of mixed sizes and blur radii on one screen: all 14 stay cached when only the
  // top-level caret moves (blurs_made delta == 0) and match a fresh render byte-for-byte.
  {
    double g14[16 * MB_INST];
    static const double blurs[4] = {1.0, 3.0, 7.0, 16.0};
    rect_at(g14, 0, 0, W, H, 0, 0.92, 0.90, 0.88, 0);
    for (int i = 0; i < 14; i++) {
      int col = i % 7, row = i / 7;
      double gx = 2 + col * 13;
      double gy = 2 + row * 32;
      double gw = 8 + i;
      double gh = 6 + i;
      double *d = g14 + (i + 1) * MB_INST;
      rect_at(d, gx, gy, gw, gh, 5, 1, 1, 1, -(101 + i));
      d[7] = blurs[i % 4];
      d[11] = 0.4;
    }
    rect_at(g14 + 15 * MB_INST, 92, 66, 2, 6, 0, 0, 0, 0, 0);
    glass_free();
    made = blurs_made;
    gl_present(g14, 16, 0.1, 0.2, 0.3);
    CHECK(blurs_made == made + 14);
    CHECK(surface_as_whole(surface));
    g14[15 * MB_INST + 0] = 94;  // only top-level caret moves
    made = blurs_made;
    gl_present(g14, 16, 0.1, 0.2, 0.3);
    CHECK(blurs_made == made);
    CHECK(kept_ok == 1);
    CHECK(surface_as_fresh(surface));
  }

  // What drawing holds beyond its frames given back: the trim lets go of glass's textures and the read back's
  // framebuffer; glass's textures go once MB_GLASS_IDLE frames in a row drew none. Each made again as it is next
  // needed, the surface then the same to the byte as the frame drawn whole.
  {
    double g1[2 * MB_INST];
    rect_at(g1, 10, 10, 40, 20, 0, 0.9, 0.1, 0.1, 0);
    rect_at(g1 + MB_INST, 5, 5, 50, 25, 6, 1, 1, 1, -5);
    g1[MB_INST + 4] = 6;
    g1[MB_INST + 7] = 2;
    g1[MB_INST + 11] = 0.3;
    g1[MB_INST + 21] = 2;
    g1[MB_INST + 23] = 1;
    glass_forget();
    gl_present(g1, 2, 0.1, 0.2, 0.3);
    CHECK(lv[0].t != 0 && lv_w > 0);
    CHECK(slots[0].bt != 0);
    CHECK(surface_as_fresh(surface));
    // the same capture frosted (kind 5), kept in the same slot
    g1[MB_INST + 5] = 5;
    g1[0] = 11;
    glass_forget();
    gl_present(g1, 2, 0.1, 0.2, 0.3);
    CHECK(slots[0].bt != 0);
    CHECK(surface_as_fresh(surface));

    CHECK(read_fb != 0);
    mb_render_trim();
    CHECK(read_fb == 0 && read_tex == 0);
    CHECK(lv[0].t == 0 && lv[4].t == 0 && lv_w == 0 && lv_h == 0);
    for (int i = 0; i < MB_GLASS_SLOTS; i++) CHECK(slots[i].bt == 0 && slots[i].under == NULL);
    g1[0] = 12;
    made = blurs_made;
    gl_present(g1, 2, 0.1, 0.2, 0.3);
    CHECK(blurs_made == made + 1);
    CHECK(lv[0].t != 0);
    CHECK(surface_as_fresh(surface));

    // frames with no glass: glass's textures kept till the MB_GLASS_IDLE-th, then let go
    double plain[MB_INST];
    rect_at(plain, 10, 10, 40, 20, 0, 0.9, 0.1, 0.1, 0);
    for (int i = 1; i <= MB_GLASS_IDLE; i++) {
      plain[0] = 10 + i % 20;
      gl_present(plain, 1, 0.1, 0.2, 0.3);
      if (i == MB_GLASS_IDLE - 1) CHECK(lv[0].t != 0 && slots[0].bt != 0);
    }
    CHECK(lv[0].t == 0 && lv_w == 0);
    for (int i = 0; i < MB_GLASS_SLOTS; i++) CHECK(slots[i].bt == 0);
    g1[0] = 13;
    made = blurs_made;
    gl_present(g1, 2, 0.1, 0.2, 0.3);
    CHECK(blurs_made == made + 1);
    CHECK(surface_as_fresh(surface));
    // a frame with glass among those without keeps them: the count starts again
    for (int i = 1; i < MB_GLASS_IDLE; i++) {
      plain[0] = 10 + i % 20;
      gl_present(plain, 1, 0.1, 0.2, 0.3);
    }
    g1[0] = 14;
    gl_present(g1, 2, 0.1, 0.2, 0.3);
    for (int i = 1; i < MB_GLASS_IDLE; i++) {
      plain[0] = 10 + i % 20;
      gl_present(plain, 1, 0.1, 0.2, 0.3);
    }
    CHECK(lv[0].t != 0);
  }

  // Unmerged liquid glass (kind 6, a[23] <= 0):
  // (1) single shape with merge=0 (tight quad + direct sd_rr) matches merge=1e-7 (merged_liquid + sd_group, same float32 quad bounds) byte-for-byte;
  // (2) two unmerged liquid shapes separated by a shadow (kind 2) sharing one capture make only 1 blur and preserve each
  //     instance's own spot, matching separate captures byte-for-byte at k == 0.
  {
    double eq[2 * MB_INST];
    rect_at(eq, 0, 0, W, H, 0, 0.85, 0.30, 0.20, 0);
    rect_at(eq + MB_INST, 18, 22, 54, 24, 6, 1, 1, 1, -9);
    eq[MB_INST + 4] = 12;
    eq[MB_INST + 6] = 1;
    eq[MB_INST + 7] = 2;
    eq[MB_INST + 11] = 0.25;
    eq[MB_INST + 12] = 0.8;
    eq[MB_INST + 13] = 8;
    eq[MB_INST + 14] = 0;
    eq[MB_INST + 15] = 1;
    eq[MB_INST + 21] = 4;
    eq[MB_INST + 22] = 0.2;
    eq[MB_INST + 23] = 0;
    glass_forget();
    gl_present(eq, 2, 0.1, 0.2, 0.3);
    unsigned char *px_single = pixels_of_fb(surface);

    eq[MB_INST + 23] = 1e-7;
    glass_forget();
    gl_present(eq, 2, 0.1, 0.2, 0.3);
    unsigned char *px_merged = pixels_of_fb(surface);
    CHECK(memcmp(px_single, px_merged, (size_t)fb_w * fb_h * 4) == 0);
    free(px_single);
    free(px_merged);

    double lq[5 * MB_INST];
    rect_at(lq, 0, 0, W, H, 0, 0.92, 0.90, 0.85, 0);
    rect_at(lq + 1 * MB_INST, 10, 46, 76, 18, 0, 0.85, 0.25, 0.20, 0);
    // left capsule (no spot, merge=0)
    rect_at(lq + 2 * MB_INST, 6, 48, 30, 14, 6, 1, 1, 1, -9);
    lq[2 * MB_INST + 4] = 7;
    lq[2 * MB_INST + 6] = 1;
    lq[2 * MB_INST + 7] = 1.5;  // sp = 3.0 -> k == 0
    lq[2 * MB_INST + 11] = 0.25;
    lq[2 * MB_INST + 12] = 0.8;
    lq[2 * MB_INST + 13] = 6;
    lq[2 * MB_INST + 14] = 0;
    lq[2 * MB_INST + 15] = 1;
    lq[2 * MB_INST + 21] = 2;
    lq[2 * MB_INST + 22] = 0;
    lq[2 * MB_INST + 23] = 0;
    // shadow between the two shapes (outside the right disc's capture box)
    rect_at(lq + 3 * MB_INST, 6, 48, 10, 6, 2, 0, 0, 0, 0);
    lq[3 * MB_INST + 7] = 1;
    lq[3 * MB_INST + 11] = 0.2;
    // right disc (with its own spot, merge=0, sharing capture -9)
    rect_at(lq + 4 * MB_INST, 68, 48, 18, 14, 6, 1, 1, 1, -9);
    lq[4 * MB_INST + 4] = 7;
    lq[4 * MB_INST + 6] = 1;
    lq[4 * MB_INST + 7] = 1.5;
    lq[4 * MB_INST + 11] = 0.25;
    lq[4 * MB_INST + 12] = 0.8;
    lq[4 * MB_INST + 13] = 6;
    lq[4 * MB_INST + 14] = 537.0 * 4096.0 + 528.0 + 1.0;
    lq[4 * MB_INST + 15] = 1;
    lq[4 * MB_INST + 21] = 2;
    lq[4 * MB_INST + 22] = 0;
    lq[4 * MB_INST + 23] = 0;

    glass_forget();
    made = blurs_made;
    gl_present(lq, 5, 0.1, 0.2, 0.3);
    CHECK(blurs_made == made + 1);
    unsigned char *px_lq_shared = pixels_of_fb(surface);

    lq[2 * MB_INST + 20] = -10;
    lq[4 * MB_INST + 20] = -11;
    glass_forget();
    made = blurs_made;
    gl_present(lq, 5, 0.1, 0.2, 0.3);
    CHECK(blurs_made == made + 2);
    unsigned char *px_lq_sep = pixels_of_fb(surface);
    CHECK(memcmp(px_lq_shared, px_lq_sep, (size_t)fb_w * fb_h * 4) == 0);
    free(px_lq_shared);
    free(px_lq_sep);
  }

  // Asymmetric 4-corner merged_liquid (rr = 14,14,0,0 sheet merged with pill) + Glass::clear() micro-veil vs pure lens:
  {
    double as[3 * MB_INST];
    rect_at(as, 0, 0, W, H, 0, 0.10, 0.12, 0.16, 0);
    rect_at(as + 1 * MB_INST, 10, 20, 48, 40, 6, 1, 1, 1, -12);
    as[1 * MB_INST + 4] = 14;
    as[1 * MB_INST + 6] = 1;
    as[1 * MB_INST + 7] = 1;
    as[1 * MB_INST + 11] = 0.25;
    as[1 * MB_INST + 12] = 0.55;
    as[1 * MB_INST + 13] = 8;
    as[1 * MB_INST + 15] = 1;
    as[1 * MB_INST + 21] = 6;
    as[1 * MB_INST + 22] = 0.18;
    as[1 * MB_INST + 23] = 8;
    as[1 * MB_INST + 36] = 14;
    as[1 * MB_INST + 37] = 14;
    as[1 * MB_INST + 38] = 0;
    as[1 * MB_INST + 39] = 0;
    rect_at(as + 2 * MB_INST, 62, 28, 20, 20, 6, 1, 1, 1, -12);
    as[2 * MB_INST + 4] = 10;
    as[2 * MB_INST + 6] = 1;
    as[2 * MB_INST + 7] = 1;
    as[2 * MB_INST + 11] = 0.25;
    as[2 * MB_INST + 12] = 0.55;
    as[2 * MB_INST + 13] = 8;
    as[2 * MB_INST + 15] = 1;
    as[2 * MB_INST + 21] = 6;
    as[2 * MB_INST + 22] = 0.18;
    as[2 * MB_INST + 23] = 8;
    as[2 * MB_INST + 36] = 10;
    as[2 * MB_INST + 37] = 10;
    as[2 * MB_INST + 38] = 10;
    as[2 * MB_INST + 39] = 10;

    glass_forget();
    gl_present(as, 3, 0.10, 0.12, 0.16);
    unsigned char *px_as = pixels_of_fb(surface);
    // RGBA8 bottom-up at scale 2
    unsigned char *bg_p = px_as + ((fb_h - 1 - 6) * fb_w + 6) * 4;
    unsigned char *tl_p = px_as + ((fb_h - 1 - 44) * fb_w + 24) * 4;  // (12, 22) outside top-left rounded corner (r=14)
    unsigned char *bl_p = px_as + ((fb_h - 1 - 116) * fb_w + 24) * 4; // (12, 58) inside bottom-left square corner (r=0)
    CHECK(abs((int)tl_p[0] - (int)bg_p[0]) <= 2 && abs((int)tl_p[1] - (int)bg_p[1]) <= 2);
    CHECK((int)bl_p[0] > 90 && (int)bl_p[1] > 90);
    free(px_as);

    double cl[3 * MB_INST];
    rect_at(cl, 0, 0, W, H, 0, 0.08, 0.08, 0.10, 0);
    rect_at(cl + 1 * MB_INST, 8, 15, 36, 40, 6, 1, 1, 1, -13);
    cl[1 * MB_INST + 4] = 10;
    cl[1 * MB_INST + 6] = 1;
    cl[1 * MB_INST + 7] = 0;
    cl[1 * MB_INST + 11] = 26.0 / 255.0;
    cl[1 * MB_INST + 12] = 0.6;
    cl[1 * MB_INST + 13] = 6;
    cl[1 * MB_INST + 15] = 1;
    cl[1 * MB_INST + 21] = 8;
    cl[1 * MB_INST + 22] = 0;
    cl[1 * MB_INST + 23] = 0;
    rect_at(cl + 2 * MB_INST, 56, 15, 36, 40, 6, 1, 1, 1, -14);
    cl[2 * MB_INST + 4] = 10;
    cl[2 * MB_INST + 6] = 1;
    cl[2 * MB_INST + 7] = 0;
    cl[2 * MB_INST + 11] = 0.0;
    cl[2 * MB_INST + 12] = 0.6;
    cl[2 * MB_INST + 13] = 6;
    cl[2 * MB_INST + 15] = 1;
    cl[2 * MB_INST + 21] = 8;
    cl[2 * MB_INST + 22] = 0;
    cl[2 * MB_INST + 23] = 0;

    glass_forget();
    gl_present(cl, 3, 0.08, 0.08, 0.10);
    unsigned char *px_cl = pixels_of_fb(surface);
    unsigned char *cl_bg = px_cl + ((fb_h - 1 - 6) * fb_w + 6) * 4;
    unsigned char *cl_veil = px_cl + ((fb_h - 1 - 70) * fb_w + 52) * 4;   // (26, 35) center of Glass::clear()
    unsigned char *cl_lens = px_cl + ((fb_h - 1 - 70) * fb_w + 148) * 4;  // (74, 35) center of pure clear optical lens
    CHECK((int)cl_veil[1] >= 44 && (int)cl_veil[1] <= 62);
    CHECK(abs((int)cl_lens[0] - (int)cl_bg[0]) <= 2 && abs((int)cl_lens[1] - (int)cl_bg[1]) <= 2);
    free(px_cl);
  }

  // A group the host keeps drawn out by its header straight into the floats: each instance moved in doubles, then
  // made a float, as the app's own instance moved there would be.
  double kept[MB_INST];
  rect_at(kept, 10.1, 20.3, 30, 20, 0, 0.5, 0.5, 0.5, 0);
  double kept_moves[1] = {0};
  mb_host_group_set(5, kept, kept_moves, 1);
  double head[MB_INST] = {0};
  head[0] = 0.2;
  head[1] = -7.7;
  head[5] = MB_GROUP_HEAD;
  head[12] = 5;
  head[13] = 0;
  head[14] = 1;
  gl_present(head, 1, 0.1, 0.2, 0.3);
  CHECK(kept_count == 1);
  CHECK(fbuf[0] == (float)(10.1 + 0.2));
  CHECK(fbuf[1] == (float)(20.3 + -7.7));
  CHECK(fbuf[2] == 30.0f);
  CHECK(fbuf[5] == 0.0f);
  CHECK(surface_as_whole(surface));
  mb_host_group_drop(5);

  if (!failed) printf("gles_render: ok\n");
  return failed;
}
