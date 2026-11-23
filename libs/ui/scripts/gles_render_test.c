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
#include <time.h>
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

// A draw that samples the texture it draws into (a sampler of the program's, active, on a unit that holds the
// framebuffer's colour attachment): a feedback loop. WebGL2 and strict GLES 3 drivers refuse it
// (GL_INVALID_OPERATION, the draw dropped); llvmpipe draws it all the same, so the test looks for it itself.
static int feedback_loops;
static void feedback_seen(void) {
  GLint fb = 0, type = 0, tex = 0, p = 0, n = 0, unit_was = 0;
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &fb);
  if (!fb) return;
  glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                        GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type);
  if (type != GL_TEXTURE) return;
  glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                        GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &tex);
  glGetIntegerv(GL_CURRENT_PROGRAM, &p);
  if (!p || !tex) return;
  glGetProgramiv(p, GL_ACTIVE_UNIFORMS, &n);
  glGetIntegerv(GL_ACTIVE_TEXTURE, &unit_was);
  for (GLint i = 0; i < n; i++) {
    char name[64];
    GLint size = 0, unit = 0, bound = 0;
    GLenum utype = 0;
    glGetActiveUniform(p, (GLuint)i, sizeof name, NULL, &size, &utype, name);
    if (utype != GL_SAMPLER_2D) continue;
    glGetUniformiv(p, glGetUniformLocation(p, name), &unit);
    glActiveTexture(GL_TEXTURE0 + unit);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound);
    if (bound == tex) {
      if (!feedback_loops) fprintf(stderr, "gles_render_test: feedback loop: %s on unit %d samples texture %d drawn into\n", name, unit, tex);
      feedback_loops++;
    }
  }
  glActiveTexture((GLenum)unit_was);
}
static int vbo_uploads;
static int instanced_draws;
static int instanced_total;
static void checked_buffer_data(GLenum target, GLsizeiptr size, const void *data, GLenum usage) {
  if (target == GL_ARRAY_BUFFER) vbo_uploads++;
  epoxy_glBufferData(target, size, data, usage);
}
static void checked_draw_arrays(GLenum mode, GLint first, GLsizei count) {
  feedback_seen();
  epoxy_glDrawArrays(mode, first, count);
}
static void checked_draw_arrays_instanced(GLenum mode, GLint first, GLsizei count, GLsizei n) {
  feedback_seen();
  instanced_draws++;
  instanced_total += n;
  epoxy_glDrawArraysInstanced(mode, first, count, n);
}
#undef glBufferData
#define glBufferData checked_buffer_data
#undef glDrawArrays
#define glDrawArrays checked_draw_arrays
#undef glDrawArraysInstanced
#define glDrawArraysInstanced checked_draw_arrays_instanced

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

// A progressive frosted glass (kind 5) across the window from y0 to y1, faded out over 8 points towards its foot
// (`to_foot`) or its top, its capture `tid`.
static void progressive_at(double *d, double y0, double y1, int to_foot, double tid) {
  rect_at(d, 0, y0, W, y1 - y0, 5, 0.96, 0.96, 0.96, tid);
  d[6] = 1.1;
  d[7] = 4.0;
  d[11] = 0.35;
  d[15] = 1.0;
  d[22] = -1.0;
  if (to_foot) {
    d[54] = y1;
    d[55] = 8.0;
  } else {
    d[52] = y0;
    d[53] = 8.0;
  }
}

// A foreground lens (kind 8) 40 points square at x, y over one child, a 16-point square of (r, g, b) at its middle.
static void lens_at(double *d, double x, double y, double r, double g, double b) {
  rect_at(d, x, y, 40, 40, 8, 1.0, 1.0, 1.0, 0);
  d[4] = 10;
  d[7] = 2.0;
  d[11] = 1.0;
  d[12] = 1.0;
  d[13] = 8.0;
  d[14] = 6.0;
  d[15] = 1.0;
  d[36] = d[37] = d[38] = d[39] = 10;
  rect_at(d + MB_INST, x + 12, y + 12, 16, 16, 0, r, g, b, 0);
}

// The texture unit `unit` holds (2D).
static GLuint bound_on(GLenum unit) {
  GLint was = 0, t = 0;
  glGetIntegerv(GL_ACTIVE_TEXTURE, &was);
  glActiveTexture(unit);
  glGetIntegerv(GL_TEXTURE_BINDING_2D, &t);
  glActiveTexture((GLenum)was);
  return (GLuint)t;
}

// A level the blurs or the lenses draw into left on a unit of the post program's after a frame.
static int level_left_bound(void) {
  for (int u = 1; u <= 3; u++) {
    GLuint t = bound_on(GL_TEXTURE0 + u);
    if (!t) continue;
    if (t == lens_lv[0].t || t == lens_lv[1].t) return 1;
    if (u != 2)
      for (int j = 0; j < 5; j++)
        if (t == lv[j].t) return 1;
  }
  return 0;
}

// Pixel rows from `py` (pixels from the window's top) to its foot the same to the byte in two readings.
static int foot_same(const unsigned char *a, const unsigned char *b, int py) {
  return memcmp(a, b, (size_t)(fb_h - py) * fb_w * 4) == 0;
}

// The luminance (0..1) at x, y points in a reading.
static double luma_at(const unsigned char *px, double x, double y) {
  const unsigned char *p = px + ((fb_h - 1 - (int)(y * S)) * fb_w + (int)(x * S)) * 4;
  return (0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]) / 255.0;
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

  // Perf-35: lazy shader compilation, ONE_KIND #if pruning, scissor glClear partial-redraw ground, and kind==9 own prog.
  {
    CHECK(progs[5].p == 0 && progs[6].p == 0 && progs[7].p == 0 && progs[8].p == 0 &&
          progs[13].p == 0 && progs[MB_KINDS].p == 0 && post == 0 && ad_prog == 0);

    // Seed a 4x4 glyph cell in atlas (unit 0) and a temporary 2x2 RGBA image for kind 4 and kind 9.
    static const unsigned char glyph_px[16] = {
        255, 255, 255, 255, 255, 200, 200, 255, 255, 200, 200, 255, 255, 255, 255, 255};
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, atlas);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 4, 4, GL_RED, GL_UNSIGNED_BYTE, glyph_px);

    static const unsigned char img_px[16] = {
        220, 40, 60, 255, 40, 210, 80, 255, 50, 90, 230, 255, 240, 220, 40, 255};
    glGenTextures(1, &picture_one);
    glBindTexture(GL_TEXTURE_2D, picture_one);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, img_px);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    double ng[4 * MB_INST];
    // 0: kind 0 rect
    rect_at(ng, 6, 8, 22, 18, 0, 0.85, 0.25, 0.15, 0);
    ng[36] = ng[37] = ng[38] = ng[39] = 4.0;
    // 1: kind 4 image
    rect_at(ng + 1 * MB_INST, 34, 8, 24, 18, 4, 1.0, 1.0, 1.0, 1);
    ng[1 * MB_INST + 12] = 0.0; ng[1 * MB_INST + 13] = 0.0;
    ng[1 * MB_INST + 14] = 1.0; ng[1 * MB_INST + 15] = 1.0;
    // 2: kind 1 glyph
    rect_at(ng + 2 * MB_INST, 66, 10, 16, 16, 1, 0.12, 0.22, 0.88, 0);
    ng[2 * MB_INST + 12] = 0.0; ng[2 * MB_INST + 13] = 0.0;
    ng[2 * MB_INST + 14] = 4.0; ng[2 * MB_INST + 15] = 4.0;
    // 3: kind 9 native view picture
    rect_at(ng + 3 * MB_INST, 12, 36, 40, 24, 9, 1.0, 1.0, 1.0, 1);
    ng[3 * MB_INST + 12] = 0.0; ng[3 * MB_INST + 13] = 0.0;
    ng[3 * MB_INST + 14] = 1.0; ng[3 * MB_INST + 15] = 1.0;
    ng[3 * MB_INST + 36] = ng[3 * MB_INST + 37] = ng[3 * MB_INST + 38] = ng[3 * MB_INST + 39] = 6.0;

    for (int oo = 0; oo <= 1; oo++) {
      over_other = oo;
      // Whole-screen draw
      ng[0] = 6;
      gl_present(ng, 4, 0.12, 0.22, 0.32);
      CHECK(surface_as_whole(surface));
      // Prime canvas with dirty rect, then trigger partial redraw (cut_on == 1)
      ng[0] = 8;
      mb_host_render_dirty(4, 6, 28, 22);
      gl_present(ng, 4, 0.12, 0.22, 0.32);
      CHECK(canvas_ok == 1);
      CHECK(surface_as_whole(surface));
      ng[0] = 10;
      ng[3 * MB_INST + 0] = 16;
      mb_host_render_dirty(6, 6, 30, 22);
      mb_host_render_dirty(10, 34, 48, 28);
      gl_present(ng, 4, 0.12, 0.22, 0.32);
      CHECK(canvas_ok == 1);
      CHECK(surface_as_whole(surface));
    }

    CHECK(progs[5].p == 0 && progs[6].p == 0 && progs[7].p == 0 && progs[8].p == 0 &&
          progs[13].p == 0 && progs[MB_KINDS].p == 0 && post == 0 && ad_prog == 0);
    CHECK(progs[0].p != 0 && progs[1].p != 0 && progs[4].p != 0 && progs[9].p != 0);

    // Restore clean state for subsequent tests (which assert canvas_fb == 0 and picture_one == 0).
    over_other = 0;
    glDeleteTextures(1, &picture_one);
    picture_one = 0;
    if (canvas_fb) {
      glDeleteFramebuffers(1, &canvas_fb);
      glDeleteTextures(1, &canvas_tex);
      canvas_lost();
    }
    glBindFramebuffer(GL_FRAMEBUFFER, surface);
  }

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

    // Wave 3A (1): clear-lens optical zoom (slot 7 = -(zoom - 1.0)) magnifies centered backdrop
    double zm[3 * MB_INST];
    rect_at(zm, 0, 0, W, H, 0, 0.05, 0.05, 0.08, 0);
    // Red square centered at (50, 35), half-width 8pt -> x in [42, 58]
    rect_at(zm + 1 * MB_INST, 42, 27, 16, 16, 0, 0.95, 0.10, 0.10, 0);
    // Clear liquid lens (10, 10, 80, 50), center (50, 35), refraction = 0
    rect_at(zm + 2 * MB_INST, 10, 10, 80, 50, 6, 1, 1, 1, -15);
    zm[2 * MB_INST + 4] = 12;
    zm[2 * MB_INST + 6] = 1;
    zm[2 * MB_INST + 7] = 0.0;  // zoom = 1.0
    zm[2 * MB_INST + 11] = 0.0;
    zm[2 * MB_INST + 12] = 0.0;
    zm[2 * MB_INST + 13] = 4;
    zm[2 * MB_INST + 15] = 1;
    zm[2 * MB_INST + 21] = 0;
    zm[2 * MB_INST + 22] = 0;
    zm[2 * MB_INST + 23] = 0;

    glass_forget();
    gl_present(zm, 3, 0.05, 0.05, 0.08);
    unsigned char *px_z1 = pixels_of_fb(surface);
    // Probe (59, 35) -> (118, 70) at 2x: outside [42, 58] at zoom=1.0 -> dark background
    unsigned char *z1_p = px_z1 + ((fb_h - 1 - 70) * fb_w + 118) * 4;
    CHECK((int)z1_p[0] < 40);
    free(px_z1);

    zm[2 * MB_INST + 7] = -0.25;  // zoom = 1.25 -> sampleBase.x = 50 + 9/1.25 = 57.2 (inside red square!)
    glass_forget();
    gl_present(zm, 3, 0.05, 0.05, 0.08);
    unsigned char *px_z2 = pixels_of_fb(surface);
    unsigned char *z2_p = px_z2 + ((fb_h - 1 - 70) * fb_w + 118) * 4;
    CHECK((int)z2_p[0] > 200);
    free(px_z2);

    // Wave 3A (2): global ambient light_angle rotates specular glint by 90 deg and restores bit-exact at 0.0
    double la_inst[2 * MB_INST];
    rect_at(la_inst, 0, 0, W, H, 0, 0.10, 0.10, 0.12, 0);
    rect_at(la_inst + 1 * MB_INST, 25, 10, 50, 50, 6, 0.12, 0.12, 0.12, -16);
    la_inst[1 * MB_INST + 4] = 12;
    la_inst[1 * MB_INST + 6] = 1;
    la_inst[1 * MB_INST + 7] = 1.0;
    la_inst[1 * MB_INST + 11] = 0.5;
    la_inst[1 * MB_INST + 12] = 1.0;
    la_inst[1 * MB_INST + 13] = 8;
    la_inst[1 * MB_INST + 15] = 1;
    la_inst[1 * MB_INST + 21] = 0;
    la_inst[1 * MB_INST + 22] = 0;
    la_inst[1 * MB_INST + 23] = 0;

    mb_host_glass_light_angle(0.0);
    glass_forget();
    gl_present(la_inst, 2, 0.10, 0.10, 0.12);
    unsigned char *px_la0 = pixels_of_fb(surface);
    // Top edge (50, 10.5) -> (100, 21); Left edge (25.5, 35) -> (51, 70)
    int top0 = (int)px_la0[((fb_h - 1 - 21) * fb_w + 100) * 4 + 1];
    int left0 = (int)px_la0[((fb_h - 1 - 70) * fb_w + 51) * 4 + 1];
    CHECK(top0 > left0 + 30);

    mb_host_glass_light_angle(1.5707963267948966);  // PI / 2
    glass_forget();
    gl_present(la_inst, 2, 0.10, 0.10, 0.12);
    unsigned char *px_la90 = pixels_of_fb(surface);
    int top90 = (int)px_la90[((fb_h - 1 - 21) * fb_w + 100) * 4 + 1];
    int left90 = (int)px_la90[((fb_h - 1 - 70) * fb_w + 51) * 4 + 1];
    int right90 = (int)px_la90[((fb_h - 1 - 70) * fb_w + 149) * 4 + 1];
    CHECK(left90 > top90 + 30);
    CHECK(right90 > top90 + 30);
    free(px_la90);

    mb_host_glass_light_angle(0.0);
    glass_forget();
    gl_present(la_inst, 2, 0.10, 0.10, 0.12);
    unsigned char *px_la0_again = pixels_of_fb(surface);
    CHECK(memcmp(px_la0, px_la0_again, (size_t)fb_w * (size_t)fb_h * 4) == 0);
    free(px_la0);
    free(px_la0_again);
  }

  // Neutral light liquid glass density (kind 6, !is_clear && !is_dark): alpha <= 0.41 keeps the 0.4032 baseline to the
  // byte (0xFDFCFD50 and 0xFDFCFD67 draw the same), while a dense veil (0xFDFCFDD9 ~ 0.851) emits its own alpha and
  // fades transmittance, lift and chroma to 0, so over black it is far brighter and over saturated blue it stays neutral.
  {
    double ld[2 * MB_INST];
    unsigned char *px_ld[4];
    // (alpha byte, backdrop r, g, b)
    static const double ld_case[4][4] = {
        {0x50, 0, 0, 0}, {0x67, 0, 0, 0}, {0xD9, 0, 0, 0}, {0xD9, 0.0, 0.4, 1.0}};
    for (int i = 0; i < 4; i++) {
      rect_at(ld, 0, 0, W, H, 0, ld_case[i][1], ld_case[i][2], ld_case[i][3], 0);
      rect_at(ld + MB_INST, 10, 10, 80, 50, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -17);
      ld[MB_INST + 4] = 12;
      ld[MB_INST + 6] = 1;
      ld[MB_INST + 7] = 1.0;
      ld[MB_INST + 11] = ld_case[i][0] / 255.0;
      ld[MB_INST + 12] = 0.0;
      ld[MB_INST + 13] = 4;
      ld[MB_INST + 15] = 1;
      ld[MB_INST + 21] = 0;
      ld[MB_INST + 22] = 0;
      ld[MB_INST + 23] = 0;
      glass_forget();
      gl_present(ld, 2, ld_case[i][1], ld_case[i][2], ld_case[i][3]);
      px_ld[i] = pixels_of_fb(surface);
    }
    // centre (50, 35) -> (100, 70) at 2x
    double ld_lum[4];
    for (int i = 0; i < 4; i++) {
      unsigned char *c = px_ld[i] + ((fb_h - 1 - 70) * fb_w + 100) * 4;
      ld_lum[i] = (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255.0;
      printf("gles_render: light glass 0x%02X over (%.1f, %.1f, %.1f): rgb %d %d %d, luma %.4f\n", (int)ld_case[i][0],
             ld_case[i][1], ld_case[i][2], ld_case[i][3], c[0], c[1], c[2], ld_lum[i]);
    }
    CHECK(memcmp(px_ld[0], px_ld[1], (size_t)fb_w * fb_h * 4) == 0);
    CHECK(ld_lum[1] >= 0.25 && ld_lum[1] <= 0.36);
    CHECK(ld_lum[2] >= 0.80 && ld_lum[2] > ld_lum[1] + 0.40);
    CHECK(px_ld[3][((fb_h - 1 - 70) * fb_w + 100) * 4 + 0] >= (int)(0.72 * 255.0 + 0.5));
    for (int i = 0; i < 4; i++) free(px_ld[i]);
  }

  // Neutral dark liquid glass density (kind 6, is_dark): alpha <= 0.41 keeps the regular baseline to the byte
  // (0x20202050 and 0x20202067 draw the same), while dense veils (0x202020BF 75%, 0x202020D9 85%) fade
  // transmittance, lift and chroma toward 0, so over white they stay dark for white ink and over saturated blue
  // chroma is cleanly attenuated.
  {
    double dd[2 * MB_INST];
    unsigned char *px_dd[5];
    // (alpha byte, backdrop r, g, b)
    static const double dd_case[5][4] = {
        {0x50, 1, 1, 1}, {0x67, 1, 1, 1}, {0xBF, 1, 1, 1}, {0xD9, 1, 1, 1}, {0xD9, 0.0, 0.4, 1.0}};
    for (int i = 0; i < 5; i++) {
      rect_at(dd, 0, 0, W, H, 0, dd_case[i][1], dd_case[i][2], dd_case[i][3], 0);
      rect_at(dd + MB_INST, 10, 10, 80, 50, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, -17);
      dd[MB_INST + 4] = 12;
      dd[MB_INST + 6] = 1;
      dd[MB_INST + 7] = 1.0;
      dd[MB_INST + 11] = dd_case[i][0] / 255.0;
      dd[MB_INST + 12] = 0.0;
      dd[MB_INST + 13] = 4;
      dd[MB_INST + 15] = 1;
      dd[MB_INST + 21] = 0;
      dd[MB_INST + 22] = 0;
      dd[MB_INST + 23] = 0;
      glass_forget();
      gl_present(dd, 2, dd_case[i][1], dd_case[i][2], dd_case[i][3]);
      px_dd[i] = pixels_of_fb(surface);
    }
    // centre (50, 35) -> (100, 70) at 2x
    double dd_lum[5];
    for (int i = 0; i < 5; i++) {
      unsigned char *c = px_dd[i] + ((fb_h - 1 - 70) * fb_w + 100) * 4;
      dd_lum[i] = (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255.0;
      printf("gles_render: dark glass 0x%02X over (%.1f, %.1f, %.1f): rgb %d %d %d, luma %.4f\n", (int)dd_case[i][0],
             dd_case[i][1], dd_case[i][2], dd_case[i][3], c[0], c[1], c[2], dd_lum[i]);
    }
    CHECK(memcmp(px_dd[0], px_dd[1], (size_t)fb_w * fb_h * 4) == 0);
    CHECK(dd_lum[1] >= 0.55 && dd_lum[1] <= 0.74);
    CHECK(dd_lum[2] <= 0.36 && dd_lum[2] <= dd_lum[1] - 0.25);
    CHECK(dd_lum[3] <= 0.30 && dd_lum[3] < dd_lum[2]);
    unsigned char *dd_blue = px_dd[4] + ((fb_h - 1 - 70) * fb_w + 100) * 4;
    CHECK(((double)dd_blue[2] - (double)dd_blue[0]) / 255.0 <= 0.28);
    for (int i = 0; i < 5; i++) free(px_dd[i]);
  }

  // Dedicated ONE_KIND=13 (unmerged liquid, merge=0) vs ONE_KIND=6 (merged liquid, merge=1e-7) with large flat
  // interior (inward >= 23), non-zero bevel/refraction/chroma/rim: must be byte-for-byte identical; and zero-copy
  // slot swap across frames + glass_free() must preserve identical pixels.
  {
    double lp[3 * MB_INST];
    rect_at(lp, 0, 0, W, H, 0, 0.12, 0.24, 0.48, 0);
    rect_at(lp + MB_INST, 20, 15, 60, 50, 0, 0.92, 0.35, 0.18, 0);
    rect_at(lp + 2 * MB_INST, 8, 6, 84, 68, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -18);
    lp[2 * MB_INST + 4] = 16;
    lp[2 * MB_INST + 6] = 1.0;
    lp[2 * MB_INST + 7] = 2.5;
    lp[2 * MB_INST + 11] = 0x67 / 255.0;
    lp[2 * MB_INST + 12] = 0.6;
    lp[2 * MB_INST + 13] = 14.0;
    lp[2 * MB_INST + 15] = 1.0;
    lp[2 * MB_INST + 21] = 18.0;
    lp[2 * MB_INST + 22] = 0.4;
    lp[2 * MB_INST + 23] = 0.0;
    glass_forget();
    gl_present(lp, 3, 0.12, 0.24, 0.48);
    unsigned char *px_single = pixels_of_fb(surface);

    lp[2 * MB_INST + 23] = 1e-7;
    glass_forget();
    gl_present(lp, 3, 0.12, 0.24, 0.48);
    unsigned char *px_merged = pixels_of_fb(surface);
    CHECK(progs[5].p != 0 && progs[6].p != 0 && progs[MB_KIND_LIQUID_SINGLE].p != 0);
    CHECK(memcmp(px_single, px_merged, (size_t)fb_w * fb_h * 4) == 0);
    free(px_merged);

    lp[2 * MB_INST + 23] = 0.0;
    for (int step = 1; step <= 4; step++) {
      lp[MB_INST + 0] = 20 + step * 3;
      gl_present(lp, 3, 0.12, 0.24, 0.48);
    }
    glass_free();
    lp[MB_INST + 0] = 20;
    gl_present(lp, 3, 0.12, 0.24, 0.48);
    unsigned char *px_after_free = pixels_of_fb(surface);
    CHECK(memcmp(px_single, px_after_free, (size_t)fb_w * fb_h * 4) == 0);
    free(px_single);
    free(px_after_free);
  }

  // Wave 7: adaptive liquid glass (slot 14 = -1.0) + adaptive kind 10 neutral/chromatic ink:
  // 0: light glass over white (bg=1.0), 1: light glass over black (bg=0.0),
  // 2: light glass over mid-tone (bg=0.50), 3: dark glass (0x20202067) over white (bg=1.0).
  {
    double ad[4 * MB_INST];
    struct { double bg; int dark_glass; double ink; } w7_cases[4] = {
      {1.0, 0, 0.11},
      {0.0, 0, 0.11},
      {0.50, 0, 0.11},
      {1.0, 1, 0.93},
    };
    for (int ci = 0; ci < 4; ci++) {
      double bg = w7_cases[ci].bg;
      int dg = w7_cases[ci].dark_glass;
      double ink = w7_cases[ci].ink;
      rect_at(ad, 0, 0, W, H, 0, bg, bg, bg, 0);
      rect_at(ad + MB_INST, 8, 6, 84, 68, 6,
              dg ? 32.0 / 255.0 : 253.0 / 255.0,
              dg ? 32.0 / 255.0 : 252.0 / 255.0,
              dg ? 32.0 / 255.0 : 253.0 / 255.0, -19);
      ad[MB_INST + 4] = 16;
      ad[MB_INST + 6] = 1.0;
      ad[MB_INST + 7] = 2.0;
      ad[MB_INST + 11] = 0x67 / 255.0;
      ad[MB_INST + 12] = 0.0;
      ad[MB_INST + 13] = 10.0;
      ad[MB_INST + 14] = -1.0;  // adaptive=true, no spot
      ad[MB_INST + 15] = 1.0;
      ad[MB_INST + 21] = 0.0;
      ad[MB_INST + 22] = 0.0;
      ad[MB_INST + 23] = 0.0;
      // Neutral line inside glass at y=28 (x=24..46)
      rect_at(ad + 2 * MB_INST, 20, 22, 30, 12, 10, ink, ink, ink, 0);
      ad[2 * MB_INST + 4] = 3.0;
      ad[2 * MB_INST + 12] = 0.1;
      ad[2 * MB_INST + 13] = 0.5;
      ad[2 * MB_INST + 14] = 0.9;
      ad[2 * MB_INST + 15] = 0.5;
      ad[2 * MB_INST + 21] = 50.0;
      ad[2 * MB_INST + 22] = 40.0;
      ad[2 * MB_INST + 23] = 34.0;
      // Chromatic accent line inside glass at y=52 (x=24..46)
      rect_at(ad + 3 * MB_INST, 20, 46, 30, 12, 10, 0.90, 0.30, 0.15, 0);
      ad[3 * MB_INST + 4] = 3.0;
      ad[3 * MB_INST + 12] = 0.1;
      ad[3 * MB_INST + 13] = 0.5;
      ad[3 * MB_INST + 14] = 0.9;
      ad[3 * MB_INST + 15] = 0.5;
      ad[3 * MB_INST + 21] = 50.0;
      ad[3 * MB_INST + 22] = 40.0;
      ad[3 * MB_INST + 23] = 34.0;
      glass_forget();
      gl_present(ad, 4, bg, bg, bg);
      unsigned char *px_ad = pixels_of_fb(surface);
      // Glass interior at (68, 40) -> (136, 80) at 2x (RGBA, y flipped)
      unsigned char *gp = px_ad + ((fb_h - 1 - 80) * fb_w + 136) * 4;
      double g_lum = (0.2126 * gp[0] + 0.7152 * gp[1] + 0.0722 * gp[2]) / 255.0;
      unsigned char *np = px_ad + ((fb_h - 1 - 56) * fb_w + 70) * 4;
      double n_lum = (0.2126 * np[0] + 0.7152 * np[1] + 0.0722 * np[2]) / 255.0;
      unsigned char *cp = px_ad + ((fb_h - 1 - 104) * fb_w + 70) * 4;
      printf("gles_render: wave7 case=%d bg=%.2f dg=%d glass=%.3f neutral_ink=%.3f chroma_rgb=%d,%d,%d\n",
             ci, bg, dg, g_lum, n_lum, cp[0], cp[1], cp[2]);
      if (ci == 0) {
        CHECK(g_lum > 0.75);
        CHECK(n_lum < 0.25);
      } else if (ci == 1) {
        CHECK(g_lum < 0.20);
        CHECK(n_lum > 0.80);
      } else if (ci == 2) {
        CHECK(g_lum > 0.55);
        CHECK(n_lum < 0.25);
      } else {
        CHECK(g_lum < 0.45);
        CHECK(n_lum > 0.85);
      }
      CHECK((int)cp[0] > (int)cp[2] + 120);
      free(px_ad);
    }

    // Smooth fogging on adaptive flip: thin bright stripe over black is softened by dual-ring fog blur + higher darkDens
    double fg[3 * MB_INST];
    double fog_peaks[2] = {0.0, 0.0};
    for (int adaptive_on = 0; adaptive_on <= 1; adaptive_on++) {
      rect_at(fg, 0, 0, W, H, 0, 0.0, 0.0, 0.0, 0);
      // Place the thin 2pt white stripe at y=48 (off the 5-point luma sample cross at y=40 and y=40+/-17)
      rect_at(fg + MB_INST, 4, 47, 92, 2, 0, 1.0, 1.0, 1.0, 0);
      rect_at(fg + 2 * MB_INST, 8, 6, 84, 68, 6,
              adaptive_on ? 253.0 / 255.0 : 32.0 / 255.0,
              adaptive_on ? 252.0 / 255.0 : 32.0 / 255.0,
              adaptive_on ? 253.0 / 255.0 : 32.0 / 255.0, -20);
      fg[2 * MB_INST + 4] = 16;
      fg[2 * MB_INST + 6] = 1.0;
      fg[2 * MB_INST + 7] = 1.0;
      fg[2 * MB_INST + 11] = 0x67 / 255.0;
      fg[2 * MB_INST + 12] = 0.0;
      fg[2 * MB_INST + 13] = 10.0;
      fg[2 * MB_INST + 14] = adaptive_on ? -1.0 : 0.0;
      fg[2 * MB_INST + 15] = 1.0;
      fg[2 * MB_INST + 21] = 0.0;
      fg[2 * MB_INST + 22] = 0.0;
      fg[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(fg, 3, 0.0, 0.0, 0.0);
      unsigned char *px_fg = pixels_of_fb(surface);
      unsigned char *sp = px_fg + ((fb_h - 1 - 96) * fb_w + 100) * 4;  // (50, 48) on the bright 2pt stripe
      fog_peaks[adaptive_on] = (0.2126 * sp[0] + 0.7152 * sp[1] + 0.0722 * sp[2]) / 255.0;
      free(px_fg);
    }
    printf("gles_render: wave7 fog stripe peak plain_dark=%.3f adaptive_fog=%.3f\n",
           fog_peaks[0], fog_peaks[1]);
    CHECK(fog_peaks[1] < fog_peaks[0] - 0.15);

    // Test A: wide 84x16pt adaptive capsule over deep navy #173255 with centered 16x10pt pure white "{less}" block
    // must resist ping-pong flipping (trimmed mean stays dark -> dark glass + white ink).
    double ta[4 * MB_INST];
    rect_at(ta, 0, 0, W, H, 0, 23.0 / 255.0, 50.0 / 255.0, 85.0 / 255.0, 0);
    rect_at(ta + MB_INST, 42, 31, 16, 10, 0, 1.0, 1.0, 1.0, 0);
    rect_at(ta + 2 * MB_INST, 8, 28, 84, 16, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -21);
    ta[2 * MB_INST + 4] = 8.0;
    ta[2 * MB_INST + 6] = 1.0;
    ta[2 * MB_INST + 7] = 2.0;
    ta[2 * MB_INST + 11] = 0x67 / 255.0;
    ta[2 * MB_INST + 12] = 0.0;
    ta[2 * MB_INST + 13] = 8.0;
    ta[2 * MB_INST + 14] = -1.0;
    ta[2 * MB_INST + 15] = 1.0;
    ta[2 * MB_INST + 21] = 0.0;
    ta[2 * MB_INST + 22] = 0.0;
    ta[2 * MB_INST + 23] = 0.0;
    rect_at(ta + 3 * MB_INST, 16, 30, 20, 12, 10, 0.11, 0.11, 0.11, 0);
    ta[3 * MB_INST + 4] = 3.0;
    ta[3 * MB_INST + 12] = 0.1;
    ta[3 * MB_INST + 13] = 0.5;
    ta[3 * MB_INST + 14] = 0.9;
    ta[3 * MB_INST + 15] = 0.5;
    ta[3 * MB_INST + 21] = 50.0;
    ta[3 * MB_INST + 22] = 36.0;
    ta[3 * MB_INST + 23] = 16.0;
    glass_forget();
    gl_present(ta, 4, 23.0 / 255.0, 50.0 / 255.0, 85.0 / 255.0);
    unsigned char *px_ta = pixels_of_fb(surface);
    unsigned char *ta_gp = px_ta + ((fb_h - 1 - 72) * fb_w + 148) * 4;  // (74, 36) glass over navy
    unsigned char *ta_np = px_ta + ((fb_h - 1 - 72) * fb_w + 52) * 4;   // (26, 36) neutral ink inside capsule
    double ta_g = (0.2126 * ta_gp[0] + 0.7152 * ta_gp[1] + 0.0722 * ta_gp[2]) / 255.0;
    double ta_n = (0.2126 * ta_np[0] + 0.7152 * ta_np[1] + 0.0722 * ta_np[2]) / 255.0;
    printf("gles_render: wave7 testA wide_less glass=%.3f ink=%.3f\n", ta_g, ta_n);
    CHECK(ta_g < 0.28);
    CHECK(ta_n > 0.80);
    free(px_ta);

    // Test B: cross-frame temporal smoothing + synchronized glass/ink + Schmitt hysteresis + auto-settle stop
    gl_set_fixed_dt(1.0 / 60.0);
    double tb[3 * MB_INST];
    rect_at(tb, 0, 0, W, H, 0, 1.0, 1.0, 1.0, 0);
    rect_at(tb + MB_INST, 8, 28, 84, 16, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -22);
    tb[MB_INST + 4] = 8.0;
    tb[MB_INST + 6] = 1.0;
    tb[MB_INST + 7] = 2.0;
    tb[MB_INST + 11] = 0x67 / 255.0;
    tb[MB_INST + 12] = 0.0;
    tb[MB_INST + 13] = 8.0;
    tb[MB_INST + 14] = -1.0;
    tb[MB_INST + 15] = 1.0;
    tb[MB_INST + 21] = 0.0;
    tb[MB_INST + 22] = 0.0;
    tb[MB_INST + 23] = 0.0;
    rect_at(tb + 2 * MB_INST, 16, 30, 20, 12, 10, 0.11, 0.11, 0.11, 0);
    tb[2 * MB_INST + 4] = 3.0;
    tb[2 * MB_INST + 12] = 0.1;
    tb[2 * MB_INST + 13] = 0.5;
    tb[2 * MB_INST + 14] = 0.9;
    tb[2 * MB_INST + 15] = 0.5;
    tb[2 * MB_INST + 21] = 50.0;
    tb[2 * MB_INST + 22] = 36.0;
    tb[2 * MB_INST + 23] = 16.0;

    // Frame 0: pure white -> instant light state
    glass_forget();
    gl_present(tb, 3, 1.0, 1.0, 1.0);
    unsigned char *px_tb = pixels_of_fb(surface);
    double f0_g = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 2]) / 255.0;
    double f0_n = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 2]) / 255.0;
    free(px_tb);
    printf("gles_render: wave7 testB f0_white glass=%.3f ink=%.3f\n", f0_g, f0_n);
    CHECK(f0_g > 0.75);
    CHECK(f0_n < 0.25);

    // Frame 1: switch to deep navy #173255 -> smooth intermediate state
    tb[8] = 23.0 / 255.0; tb[9] = 50.0 / 255.0; tb[10] = 85.0 / 255.0;
    gl_present(tb, 3, tb[8], tb[9], tb[10]);
    px_tb = pixels_of_fb(surface);
    double f1_g = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 2]) / 255.0;
    double f1_n = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 2]) / 255.0;
    free(px_tb);
    printf("gles_render: wave7 testB f1_navy glass=%.3f ink=%.3f settling=%d\n", f1_g, f1_n, gl_adaptive_settling());
    CHECK(f1_g > 0.28 && f1_g < 0.72);
    CHECK(f1_n > 0.15 && f1_n < 0.75);
    CHECK(gl_adaptive_settling() == 1);

    // Step 25 more frames (~420ms): monotonic convergence to dark state
    double prev_g = f1_g, prev_n = f1_n;
    for (int s = 0; s < 25; s++) {
      gl_present(tb, 3, tb[8], tb[9], tb[10]);
      px_tb = pixels_of_fb(surface);
      double cg = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 2]) / 255.0;
      double cn = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 2]) / 255.0;
      free(px_tb);
      CHECK(cg <= prev_g + 0.015);
      CHECK(cn >= prev_n - 0.015);
      prev_g = cg;
      prev_n = cn;
    }
    printf("gles_render: wave7 testB f26_dark glass=%.3f ink=%.3f settling=%d\n", prev_g, prev_n, gl_adaptive_settling());
    CHECK(prev_g < 0.28);
    CHECK(prev_n > 0.85);

    // Schmitt hysteresis: bg=0.40 (in [0.36, 0.46]) for 25 frames stays dark
    tb[8] = 0.40; tb[9] = 0.40; tb[10] = 0.40;
    for (int s = 0; s < 25; s++) gl_present(tb, 3, 0.40, 0.40, 0.40);
    px_tb = pixels_of_fb(surface);
    double hyst_g = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 2]) / 255.0;
    double hyst_n = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 2]) / 255.0;
    free(px_tb);
    printf("gles_render: wave7 testB hyst_0.40 glass=%.3f ink=%.3f\n", hyst_g, hyst_n);
    CHECK(hyst_g < 0.40);
    CHECK(hyst_n > 0.80);

    // Return to bright bg=0.95: frame 1 intermediate, +26 frames settles back to light and stops settling
    tb[8] = 0.95; tb[9] = 0.95; tb[10] = 0.95;
    gl_present(tb, 3, 0.95, 0.95, 0.95);
    px_tb = pixels_of_fb(surface);
    double r1_g = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 2]) / 255.0;
    double r1_n = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 2]) / 255.0;
    free(px_tb);
    printf("gles_render: wave7 testB return_f1 glass=%.3f ink=%.3f\n", r1_g, r1_n);
    CHECK(r1_g > 0.30 && r1_g < 0.82);
    CHECK(r1_n > 0.20 && r1_n < 0.88);
    for (int s = 0; s < 26; s++) gl_present(tb, 3, 0.95, 0.95, 0.95);
    px_tb = pixels_of_fb(surface);
    double r_end_g = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 2]) / 255.0;
    double r_end_n = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 2]) / 255.0;
    free(px_tb);
    printf("gles_render: wave7 testB return_end glass=%.3f ink=%.3f settling=%d\n", r_end_g, r_end_n, gl_adaptive_settling());
    CHECK(r_end_g > 0.75);
    CHECK(r_end_n < 0.25);
    CHECK(gl_adaptive_settling() == 0);
    gl_set_fixed_dt(0.0);
    glass_forget();

    // Test C: wide adaptive light capsule spanning left 45% dark (#141418) + right 55% white (#FFFFFF).
    // Verifies: whole capsule stays light, left-half neutral ink (kind 10 & kind 7) inverts bright locally,
    // right-half neutral ink stays dark, left chromatic accent preserves hue, out-of-bd elements stay dark,
    // and expanding to full dark converges the whole capsule and all ink to dark glass with light ink.
    {
      unsigned char solid_glyph[16 * 16];
      memset(solid_glyph, 255, sizeof(solid_glyph));
      glBindTexture(GL_TEXTURE_2D, atlas);
      glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
      glTexSubImage2D(GL_TEXTURE_2D, 0, 16, 16, 16, 16, GL_RED, GL_UNSIGNED_BYTE, solid_glyph);
      double tc[9 * MB_INST];
      rect_at(tc, 0, 0, W, H, 0, 1.0, 1.0, 1.0, 0);
      rect_at(tc + MB_INST, 0, 0, 46, H, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
      rect_at(tc + 2 * MB_INST, 8, 28, 84, 16, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -23);
      tc[2 * MB_INST + 4] = 8.0;
      tc[2 * MB_INST + 6] = 1.0;
      tc[2 * MB_INST + 7] = 2.0;
      tc[2 * MB_INST + 11] = 0x67 / 255.0;
      tc[2 * MB_INST + 12] = 0.0;
      tc[2 * MB_INST + 13] = 8.0;
      tc[2 * MB_INST + 14] = -1.0;
      tc[2 * MB_INST + 15] = 1.0;
      tc[2 * MB_INST + 21] = 0.0;
      tc[2 * MB_INST + 22] = 0.0;
      tc[2 * MB_INST + 23] = 0.0;
      // 3: Left subtle ink (kind 10) at center (16, 36) -> px (32, 72)
      rect_at(tc + 3 * MB_INST, 12, 30, 8, 12, 10, 0.34, 0.36, 0.38, 0);
      tc[3 * MB_INST + 4] = 3.0;
      tc[3 * MB_INST + 12] = 0.1; tc[3 * MB_INST + 13] = 0.5;
      tc[3 * MB_INST + 14] = 0.9; tc[3 * MB_INST + 15] = 0.5;
      tc[3 * MB_INST + 21] = 50.0; tc[3 * MB_INST + 22] = 36.0; tc[3 * MB_INST + 23] = 16.0;
      // 4: Left text glyph (kind 7) at center (26, 36) -> px (52, 72)
      rect_at(tc + 4 * MB_INST, 22, 32, 8, 8, 7, 0.14, 0.15, 0.17, 0);
      tc[4 * MB_INST + 12] = 16.0; tc[4 * MB_INST + 13] = 16.0;
      tc[4 * MB_INST + 14] = 16.0; tc[4 * MB_INST + 15] = 16.0;
      tc[4 * MB_INST + 21] = 50.0; tc[4 * MB_INST + 22] = 36.0; tc[4 * MB_INST + 23] = 16.0;
      // 5: Left chromatic accent (kind 10) at center (36, 36) -> px (72, 72)
      rect_at(tc + 5 * MB_INST, 32, 30, 8, 12, 10, 0.90, 0.30, 0.15, 0);
      tc[5 * MB_INST + 4] = 3.0;
      tc[5 * MB_INST + 12] = 0.1; tc[5 * MB_INST + 13] = 0.5;
      tc[5 * MB_INST + 14] = 0.9; tc[5 * MB_INST + 15] = 0.5;
      tc[5 * MB_INST + 21] = 50.0; tc[5 * MB_INST + 22] = 36.0; tc[5 * MB_INST + 23] = 16.0;
      // 6: Right subtle ink (kind 10) at center (65, 36) -> px (130, 72)
      rect_at(tc + 6 * MB_INST, 60, 30, 10, 12, 10, 0.34, 0.36, 0.38, 0);
      tc[6 * MB_INST + 4] = 3.0;
      tc[6 * MB_INST + 12] = 0.1; tc[6 * MB_INST + 13] = 0.5;
      tc[6 * MB_INST + 14] = 0.9; tc[6 * MB_INST + 15] = 0.5;
      tc[6 * MB_INST + 21] = 50.0; tc[6 * MB_INST + 22] = 36.0; tc[6 * MB_INST + 23] = 16.0;
      // 7: Right text glyph (kind 7) at center (76, 36) -> px (152, 72)
      rect_at(tc + 7 * MB_INST, 72, 32, 8, 8, 7, 0.14, 0.15, 0.17, 0);
      tc[7 * MB_INST + 12] = 16.0; tc[7 * MB_INST + 13] = 16.0;
      tc[7 * MB_INST + 14] = 16.0; tc[7 * MB_INST + 15] = 16.0;
      tc[7 * MB_INST + 21] = 50.0; tc[7 * MB_INST + 22] = 36.0; tc[7 * MB_INST + 23] = 16.0;
      // 8: Out-of-bd guard (kind 10) at (6, 4) -> px (12, 8), outside capsule bd capture rect
      rect_at(tc + 8 * MB_INST, 2, 1, 8, 6, 10, 0.34, 0.36, 0.38, 0);
      tc[8 * MB_INST + 4] = 2.0;
      tc[8 * MB_INST + 12] = 0.1; tc[8 * MB_INST + 13] = 0.5;
      tc[8 * MB_INST + 14] = 0.9; tc[8 * MB_INST + 15] = 0.5;
      tc[8 * MB_INST + 21] = 50.0; tc[8 * MB_INST + 22] = 36.0; tc[8 * MB_INST + 23] = 16.0;

      gl_set_fixed_dt(1.0 / 60.0);
      glass_forget();
      gl_present(tc, 9, 1.0, 1.0, 1.0);
      unsigned char *px_tc = pixels_of_fb(surface);
      unsigned char *p_ls = px_tc + ((fb_h - 1 - 72) * fb_w + 32) * 4;
      unsigned char *p_lt = px_tc + ((fb_h - 1 - 72) * fb_w + 52) * 4;
      unsigned char *p_lc = px_tc + ((fb_h - 1 - 72) * fb_w + 72) * 4;
      unsigned char *p_rs = px_tc + ((fb_h - 1 - 72) * fb_w + 130) * 4;
      unsigned char *p_rt = px_tc + ((fb_h - 1 - 72) * fb_w + 152) * 4;
      unsigned char *p_rg = px_tc + ((fb_h - 1 - 72) * fb_w + 170) * 4;
      unsigned char *p_ob = px_tc + ((fb_h - 1 - 8) * fb_w + 12) * 4;
      double l_sub = (0.2126 * p_ls[0] + 0.7152 * p_ls[1] + 0.0722 * p_ls[2]) / 255.0;
      double l_txt = (0.2126 * p_lt[0] + 0.7152 * p_lt[1] + 0.0722 * p_lt[2]) / 255.0;
      double r_sub = (0.2126 * p_rs[0] + 0.7152 * p_rs[1] + 0.0722 * p_rs[2]) / 255.0;
      double r_txt = (0.2126 * p_rt[0] + 0.7152 * p_rt[1] + 0.0722 * p_rt[2]) / 255.0;
      double g_right = (0.2126 * p_rg[0] + 0.7152 * p_rg[1] + 0.0722 * p_rg[2]) / 255.0;
      double oob_sub = (0.2126 * p_ob[0] + 0.7152 * p_ob[1] + 0.0722 * p_ob[2]) / 255.0;
      printf("gles_render: wave7 testC half_dark l_sub=%.3f l_txt=%.3f r_sub=%.3f r_txt=%.3f g_right=%.3f oob=%.3f chroma=%d,%d,%d\n",
             l_sub, l_txt, r_sub, r_txt, g_right, oob_sub, p_lc[0], p_lc[1], p_lc[2]);
      CHECK(l_sub > 0.82);
      CHECK(l_txt > 0.82);
      CHECK(r_sub < 0.45);
      CHECK(r_txt < 0.45);
      CHECK(g_right > 0.75);
      CHECK(oob_sub < 0.45);
      CHECK((int)p_lc[0] > (int)p_lc[2] + 120);
      free(px_tc);

      // Expand dark backdrop from 45% to 100% across 20 frames + 10 settle frames:
      // whole capsule and all ink converge to dark glass with light ink.
      double min_l_sub = 1.0, min_l_txt = 1.0, end_r_sub = 0.0, end_g_right = 1.0;
      for (int s = 0; s < 30; s++) {
        double t = s < 20 ? (double)(s + 1) / 20.0 : 1.0;
        tc[MB_INST + 2] = 46.0 + ((double)W - 46.0) * t;
        gl_present(tc, 9, 1.0, 1.0, 1.0);
        px_tc = pixels_of_fb(surface);
        p_ls = px_tc + ((fb_h - 1 - 72) * fb_w + 32) * 4;
        p_lt = px_tc + ((fb_h - 1 - 72) * fb_w + 52) * 4;
        p_rs = px_tc + ((fb_h - 1 - 72) * fb_w + 130) * 4;
        p_rg = px_tc + ((fb_h - 1 - 72) * fb_w + 170) * 4;
        double cs = (0.2126 * p_ls[0] + 0.7152 * p_ls[1] + 0.0722 * p_ls[2]) / 255.0;
        double ct = (0.2126 * p_lt[0] + 0.7152 * p_lt[1] + 0.0722 * p_lt[2]) / 255.0;
        end_r_sub = (0.2126 * p_rs[0] + 0.7152 * p_rs[1] + 0.0722 * p_rs[2]) / 255.0;
        end_g_right = (0.2126 * p_rg[0] + 0.7152 * p_rg[1] + 0.0722 * p_rg[2]) / 255.0;
        if (cs < min_l_sub) min_l_sub = cs;
        if (ct < min_l_txt) min_l_txt = ct;
        free(px_tc);
      }
      printf("gles_render: wave7 testC scroll_to_full min_l_sub=%.3f min_l_txt=%.3f end_r_sub=%.3f end_g_right=%.3f\n",
             min_l_sub, min_l_txt, end_r_sub, end_g_right);
      CHECK(end_r_sub > 0.68);
      CHECK(end_g_right < 0.35);
      gl_set_fixed_dt(0.0);
      glass_forget();
    }
    // Wave 4B v17: foreground optical lens (kind == 8): offscreen Gaussian defocus + spherical bevel refraction + SDF clip
    double k8[3 * MB_INST];
    rect_at(k8, 0, 0, W, H, 0, 1.0, 1.0, 1.0, 0);
    rect_at(k8 + MB_INST, 15, 10, 70, 60, 8, 1.0, 1.0, 1.0, 0);
    k8[MB_INST + 4] = 16;
    k8[MB_INST + 7] = 3.0;   // blur = 3pt
    k8[MB_INST + 11] = 1.0;  // alpha = 1
    k8[MB_INST + 12] = 1.0;  // child_n = 1
    k8[MB_INST + 13] = 18.0; // bezel = 18pt
    k8[MB_INST + 14] = 14.0; // refraction = 14pt
    k8[MB_INST + 15] = 1.0;
    k8[MB_INST + 36] = 16; k8[MB_INST + 37] = 16; k8[MB_INST + 38] = 16; k8[MB_INST + 39] = 16;
    rect_at(k8 + 2 * MB_INST, 38, 28, 24, 24, 0, 1.0, 0.0, 0.0, 0);
    gl_present(k8, 3, 1.0, 1.0, 1.0);
    unsigned char *px_k8 = pixels_of_fb(surface);
    // RGBA at 2x (y flipped): center (50,40)->(100,80), blur halo (35,40)->(70,80), outside SDF (5,40)->(10,80)
    unsigned char *k8_ctr = px_k8 + ((fb_h - 1 - 80) * fb_w + 100) * 4;
    unsigned char *k8_halo = px_k8 + ((fb_h - 1 - 80) * fb_w + 70) * 4;
    unsigned char *k8_out = px_k8 + ((fb_h - 1 - 80) * fb_w + 10) * 4;
    printf("gles_render: kind8 lens ctr=%d,%d,%d halo=%d,%d,%d out=%d,%d,%d\n",
           k8_ctr[0], k8_ctr[1], k8_ctr[2], k8_halo[0], k8_halo[1], k8_halo[2], k8_out[0], k8_out[1], k8_out[2]);
    CHECK((int)k8_ctr[0] - (int)k8_ctr[2] > 120);
    CHECK((int)k8_halo[0] - (int)k8_halo[2] > 20);
    CHECK(abs((int)k8_out[0] - (int)k8_out[2]) <= 2 && k8_out[0] >= 250);
    free(px_k8);
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

  // IME height sliding hits top-bar glass cache, and gradually growing glass height stays in one 256px level bucket
  // without rebuilding levels or clearing unchanged glass slots.
  {
    int saved_fb_w = fb_w, saved_fb_h = fb_h;
    double saved_w = cur_w, saved_h = cur_h, saved_scale = cur_scale;
    GLuint saved_target = target_fb;

    const int BW = 300, BH = 500, BS = 2;
    fb_w = BW * BS;
    fb_h = BH * BS;
    cur_w = BW;
    cur_h = BH;
    cur_scale = BS;
    GLuint big_tex, big_fb;
    glGenTextures(1, &big_tex);
    glBindTexture(GL_TEXTURE_2D, big_tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
    glGenFramebuffers(1, &big_fb);
    glBindFramebuffer(GL_FRAMEBUFFER, big_fb);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, big_tex, 0);
    CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
    target_fb = big_fb;
    glass_free();

    // (1) IME cur_h sliding: top-bar glass stays cached (blurs_made +1 per step, only bottom bar re-blurred)
    double ime_inst[5 * MB_INST];
    static const double ime_hs[5] = {460, 420, 380, 420, 460};
    rect_at(ime_inst, 0, 0, BW, BH, 0, 0.94, 0.94, 0.92, 0);
    ime_inst[18] = BW; ime_inst[19] = BH;
    rect_at(ime_inst + 1 * MB_INST, 20, 12, 120, 20, 0, 0.85, 0.20, 0.20, 0);
    ime_inst[1 * MB_INST + 18] = BW; ime_inst[1 * MB_INST + 19] = BH;
    rect_at(ime_inst + 2 * MB_INST, 10, 6, 280, 32, 5, 1, 1, 1, -20);
    ime_inst[2 * MB_INST + 7] = 3;
    ime_inst[2 * MB_INST + 11] = 0.4;
    ime_inst[2 * MB_INST + 18] = BW; ime_inst[2 * MB_INST + 19] = BH;
    rect_at(ime_inst + 3 * MB_INST, 20, 466, 120, 20, 0, 0.20, 0.30, 0.85, 0);
    ime_inst[3 * MB_INST + 18] = BW; ime_inst[3 * MB_INST + 19] = BH;
    rect_at(ime_inst + 4 * MB_INST, 10, 460, 280, 32, 5, 1, 1, 1, -21);
    ime_inst[4 * MB_INST + 7] = 3;
    ime_inst[4 * MB_INST + 11] = 0.4;
    ime_inst[4 * MB_INST + 18] = BW; ime_inst[4 * MB_INST + 19] = BH;

    made = blurs_made;
    gl_present(ime_inst, 5, 0.1, 0.2, 0.3);
    CHECK(blurs_made == made + 2);
    CHECK(surface_as_fresh(big_fb));
    for (int i = 0; i < 5; i++) {
      cur_h = ime_hs[i];
      ime_inst[3 * MB_INST + 1] = cur_h - 34;
      ime_inst[4 * MB_INST + 1] = cur_h - 40;
      made = blurs_made;
      gl_present(ime_inst, 5, 0.1, 0.2, 0.3);
      CHECK(blurs_made == made + 1);
      CHECK(surface_as_fresh(big_fb));
    }

    // (2) Glass height growing from 100px to 220px (+12px/step, 10 steps): levels_rebuilt <= 1, unchanged glass hits cache
    cur_h = BH;
    glass_free();
    int rb0 = levels_rebuilt;
    double grow_inst[5 * MB_INST];
    rect_at(grow_inst, 0, 0, BW, BH, 0, 0.92, 0.90, 0.88, 0);
    grow_inst[18] = BW; grow_inst[19] = BH;
    rect_at(grow_inst + 1 * MB_INST, 20, 14, 100, 24, 0, 0.15, 0.65, 0.25, 0);
    grow_inst[1 * MB_INST + 18] = BW; grow_inst[1 * MB_INST + 19] = BH;
    rect_at(grow_inst + 2 * MB_INST, 10, 10, 160, 32, 5, 1, 1, 1, -22);
    grow_inst[2 * MB_INST + 7] = 2;
    grow_inst[2 * MB_INST + 11] = 0.4;
    grow_inst[2 * MB_INST + 18] = BW; grow_inst[2 * MB_INST + 19] = BH;
    rect_at(grow_inst + 3 * MB_INST, 20, 140, 100, 120, 0, 0.75, 0.25, 0.15, 0);
    grow_inst[3 * MB_INST + 18] = BW; grow_inst[3 * MB_INST + 19] = BH;
    rect_at(grow_inst + 4 * MB_INST, 10, 120, 160, 50, 5, 1, 1, 1, -23);
    grow_inst[4 * MB_INST + 7] = 2;
    grow_inst[4 * MB_INST + 11] = 0.4;
    grow_inst[4 * MB_INST + 18] = BW; grow_inst[4 * MB_INST + 19] = BH;

    for (int step = 0; step < 10; step++) {
      // height in pt: 50 + step * 6 -> 100px..208px (+ margin 16px = 132px..240px, within one 256px bucket)
      grow_inst[4 * MB_INST + 3] = 50.0 + step * 6.0;
      made = blurs_made;
      gl_present(grow_inst, 5, 0.1, 0.2, 0.3);
      CHECK(blurs_made == made + (step == 0 ? 2 : 1));
      CHECK(surface_as_whole(big_fb));
    }
    CHECK(surface_as_fresh(big_fb));
    CHECK(levels_rebuilt - rb0 <= 1);

    glass_free();
    glBindFramebuffer(GL_FRAMEBUFFER, saved_target);
    glDeleteFramebuffers(1, &big_fb);
    glDeleteTextures(1, &big_tex);
    fb_w = saved_fb_w;
    fb_h = saved_fb_h;
    cur_w = saved_w;
    cur_h = saved_h;
    cur_scale = saved_scale;
    target_fb = saved_target;
  }

  // A selection changes shape data while two adaptive glasses share a backdrop. Each host-added settle
  // region must redraw the complete shared capture, so no previous glass or caret enters the new blur.
  {
    double a[6 * MB_INST];
    rect_at(a, 0, 0, W, H, 0, 0.95, 0.95, 0.95, 0);
    rect_at(a + MB_INST, 14, 54, 40, 3, 0, 0.1, 0.1, 0.1, 0);
    rect_at(a + 2 * MB_INST, 10, 29, 35, 8, 6, 0.99, 0.99, 0.99, -1);
    a[2 * MB_INST + 4] = 4.0;
    a[2 * MB_INST + 6] = 1.0;
    a[2 * MB_INST + 7] = 4.0;
    a[2 * MB_INST + 11] = 0x67 / 255.0;
    a[2 * MB_INST + 13] = 8.0;
    a[2 * MB_INST + 14] = -1.0;
    a[2 * MB_INST + 15] = 1.0;
    a[2 * MB_INST + 21] = 6.0;
    rect_at(a + 3 * MB_INST, 8, 45, 84, 23, 6, 0.99, 0.99, 0.99, -1);
    a[3 * MB_INST + 4] = 8.0;
    a[3 * MB_INST + 6] = 1.0;
    a[3 * MB_INST + 7] = 4.0;
    a[3 * MB_INST + 11] = 0x67 / 255.0;
    a[3 * MB_INST + 13] = 8.0;
    a[3 * MB_INST + 14] = -1.0;
    a[3 * MB_INST + 15] = 1.0;
    a[3 * MB_INST + 21] = 6.0;
    rect_at(a + 4 * MB_INST, 10, 2, 30, 3, 0, 0.4, 0.6, 1.0, 0);
    a[4 * MB_INST + 11] = 0.0;
    rect_at(a + 5 * MB_INST, 0, 0, 0, 0, 12, 0, 0, 0, 0);
    glass_forget();
    gl_set_fixed_dt(1.0 / 60.0);
    gl_present(a, 6, 0.95, 0.95, 0.95);
    gl_dirty_add(0, 0, W, H);
    a[8] = 0.93;
    gl_present(a, 6, 0.95, 0.95, 0.95);
    CHECK(gl_adaptive_settling());
    a[4 * MB_INST + 11] = 0.5;
    a[5 * MB_INST + 12] = 1.0;
    gl_dirty_add(8, 0, 36, 8);
    gl_present(a, 6, 0.95, 0.95, 0.95);
    slots_invalidate();
    CHECK(surface_as_whole(surface));
    gl_set_fixed_dt(0.0);
    glass_forget();
  }

  // Two independent adaptive liquid glasses spaced 8pt apart so their captures overlap, with a high-contrast blue
  // foreground caret drawn after the lower glass. Three consecutive partial frames updating only the top non-glass
  // region while settling must stay pixel-identical to a whole redraw, and overlapping settle damage merges to one.
  {
    double a[7 * MB_INST];
    rect_at(a, 0, 0, W, H, 0, 0.95, 0.95, 0.95, 0);
    rect_at(a + MB_INST, 14, 50, 40, 3, 0, 0.1, 0.1, 0.1, 0);
    rect_at(a + 2 * MB_INST, 10, 20, 35, 10, 6, 0.99, 0.99, 0.99, -1);
    a[2 * MB_INST + 4] = 4.0;
    a[2 * MB_INST + 6] = 1.0;
    a[2 * MB_INST + 7] = 2.1;
    a[2 * MB_INST + 11] = 0x67 / 255.0;
    a[2 * MB_INST + 13] = 8.0;
    a[2 * MB_INST + 14] = -1.0;
    a[2 * MB_INST + 15] = 1.0;
    a[2 * MB_INST + 21] = 28.0;
    rect_at(a + 3 * MB_INST, 8, 38, 84, 24, 6, 0.99, 0.99, 0.99, -2);
    a[3 * MB_INST + 4] = 8.0;
    a[3 * MB_INST + 6] = 1.0;
    a[3 * MB_INST + 7] = 4.0;
    a[3 * MB_INST + 11] = 0x67 / 255.0;
    a[3 * MB_INST + 13] = 8.0;
    a[3 * MB_INST + 14] = -1.0;
    a[3 * MB_INST + 15] = 1.0;
    a[3 * MB_INST + 21] = 28.0;
    rect_at(a + 4 * MB_INST, 16, 44, 2, 12, 0, 0.05, 0.35, 1.0, 0);
    rect_at(a + 5 * MB_INST, 10, 2, 30, 4, 0, 0.4, 0.6, 1.0, 0);
    a[5 * MB_INST + 11] = 0.0;
    rect_at(a + 6 * MB_INST, 0, 0, 0, 0, 12, 0, 0, 0, 0);
    glass_forget();
    gl_set_fixed_dt(1.0 / 60.0);
    gl_present(a, 7, 0.95, 0.95, 0.95);
    gl_dirty_add(0, 0, W, H);
    a[8] = 0.93;
    gl_present(a, 7, 0.95, 0.95, 0.95);
    CHECK(gl_adaptive_settling());
    for (int step = 0; step < 3; step++) {
      a[5 * MB_INST + 11] = 0.3 * (step + 1);
      a[6 * MB_INST + 12] = (double)(step + 1);
      gl_dirty_add(8, 0, 36, 8);
      gl_present(a, 7, 0.95, 0.95, 0.95);
      slots_invalidate();
      CHECK(surface_as_whole(surface));
    }
    float f[7 * MB_INST];
    for (int i = 0; i < 7 * MB_INST; i++) f[i] = (float)a[i];
    double r[][4] = {{6, 16, 43, 18}, {4, 34, 92, 32}};
    int rn = 2;
    CHECK(mb_glass_damage_expand(f, 7, r, &rn, W, H, S));
    CHECK(rn == 1);
    gl_set_fixed_dt(0.0);
    glass_forget();
  }

  // Captures reached through another capture are closed too, including every shape of a merged liquid group.
  {
    float f[4 * MB_INST] = {0};
    const float x[] = {70, 10, 40, 160};
    const float id[] = {-2, -1, -1, -3};
    for (int i = 0; i < 4; i++) {
      float *a = f + i * MB_INST;
      a[0] = x[i]; a[1] = 40; a[2] = 10; a[3] = 10; a[5] = 6; a[20] = id[i];
    }
    f[MB_INST + 23] = 8;
    double r[][4] = {{12, 42, 1, 1}};
    int rn = 1;
    CHECK(mb_glass_damage_expand(f, 4, r, &rn, 200, 100, 1));
    CHECK(rn == 1);
    CHECK(r[0][0] <= 0 && r[0][0] + r[0][2] >= 84 && r[0][0] + r[0][2] < 150);
  }

  // Perf-29: (1) Stacked glass cache independence (top progressive blur + top liquid glass capsule + changing bottom
  // content must produce 0 blur rebuilds, while changing content under top progressive blur rebuilds both identically
  // to a fresh render); (2) GLES async PBO+fence same-side early stop within 4 frames; (3) progressive blur visible-box
  // scissor & ramp boundary fast-path pixel equivalence.
  {
    double sg[5 * MB_INST];
    // 0: full background
    rect_at(sg, 0, 0, W, H, 0, 0.94, 0.94, 0.92, 0);
    // 1: top content under progressive blur
    rect_at(sg + 1 * MB_INST, 10, 4, 40, 10, 0, 0.85, 0.20, 0.20, 0);
    // 2: bottom unrelated content (far below top glass & its blur margin)
    rect_at(sg + 2 * MB_INST, 10, 62, 60, 10, 0, 0.20, 0.45, 0.90, 0);
    // 3: top progressive frosted blur (kind 5, a[22] = -1, fade y from 14..22)
    rect_at(sg + 3 * MB_INST, 0, 0, W, 22, 5, 0.96, 0.96, 0.96, -30);
    sg[3 * MB_INST + 6] = 1.1;
    sg[3 * MB_INST + 7] = 4.0;
    sg[3 * MB_INST + 11] = 0.35;
    sg[3 * MB_INST + 15] = 1.0;
    sg[3 * MB_INST + 22] = -1.0;
    sg[3 * MB_INST + 54] = 22.0;  // fade bottom end
    sg[3 * MB_INST + 55] = 8.0;   // fade bottom length (y=0..14 full ramp=1, 14..22 ramp->0)
    // 4: top liquid glass capsule stacked over the progressive blur
    rect_at(sg + 4 * MB_INST, 12, 4, 44, 12, 6, 0.99, 0.99, 0.99, -31);
    sg[4 * MB_INST + 4] = 6.0;
    sg[4 * MB_INST + 6] = 1.0;
    sg[4 * MB_INST + 7] = 2.0;
    sg[4 * MB_INST + 11] = 0x67 / 255.0;
    sg[4 * MB_INST + 13] = 8.0;
    sg[4 * MB_INST + 14] = -1.0;
    sg[4 * MB_INST + 15] = 1.0;
    sg[4 * MB_INST + 21] = 4.0;

    glass_forget();
    gl_set_fixed_dt(1.0 / 60.0);
    made = blurs_made;
    gl_present(sg, 5, 0.94, 0.94, 0.92);
    CHECK(blurs_made == made + 2);
    CHECK(surface_as_fresh(surface));

    // Mutate bottom unrelated rect across 3 frames: neither top progressive nor stacked liquid glass may re-blur.
    for (int step = 0; step < 3; step++) {
      sg[2 * MB_INST + 8] = 0.20 + 0.25 * (step + 1);
      made = blurs_made;
      gl_present(sg, 5, 0.94, 0.94, 0.92);
      CHECK(blurs_made == made);
      CHECK(surface_as_fresh(surface));
    }

    // Mutate content under the top progressive blur: both top progressive and stacked liquid glass must re-blur.
    sg[1 * MB_INST + 9] = 0.80;
    made = blurs_made;
    gl_present(sg, 5, 0.94, 0.94, 0.92);
    CHECK(blurs_made == made + 2);
    CHECK(surface_as_fresh(surface));

    // GLES async PBO+fence same-side early stop: light->light (0.94 -> 0.92) stops settling within 4 frames.
    double es[3 * MB_INST];
    rect_at(es, 0, 0, W, H, 0, 0.95, 0.95, 0.95, 0);
    rect_at(es + MB_INST, 8, 28, 84, 16, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -32);
    es[MB_INST + 4] = 8.0;
    es[MB_INST + 6] = 1.0;
    es[MB_INST + 7] = 2.0;
    es[MB_INST + 11] = 0x67 / 255.0;
    es[MB_INST + 13] = 8.0;
    es[MB_INST + 14] = -1.0;
    es[MB_INST + 15] = 1.0;
    rect_at(es + 2 * MB_INST, 16, 30, 20, 12, 10, 0.11, 0.11, 0.11, 0);
    es[2 * MB_INST + 4] = 3.0;
    es[2 * MB_INST + 12] = 0.1; es[2 * MB_INST + 13] = 0.5;
    es[2 * MB_INST + 14] = 0.9; es[2 * MB_INST + 15] = 0.5;
    es[2 * MB_INST + 21] = 50.0; es[2 * MB_INST + 22] = 36.0; es[2 * MB_INST + 23] = 16.0;
    glass_forget();
    gl_present(es, 3, 0.95, 0.95, 0.95);
    CHECK(gl_adaptive_settling() == 0);
    es[8] = 0.93; es[9] = 0.93; es[10] = 0.93;
    gl_present(es, 3, 0.93, 0.93, 0.93);
    CHECK(gl_adaptive_settling() == 1);
    for (int s = 0; s < 4 && gl_adaptive_settling(); s++) {
      gl_present(es, 3, 0.93, 0.93, 0.93);
    }
    CHECK(gl_adaptive_settling() == 0);
    gl_set_fixed_dt(0.0);
    glass_forget();
  }

  // Glass after glass in one frame and the next: no pass samples a level it draws into. A progressive blur binds
  // lv[1..3] for its composite and a lens its level as the backdrop; left bound, the next blur's passes (into those
  // levels) or the next lens's (into its own) are feedback loops, dropped by WebGL2 and strict GLES 3 drivers and the
  // glass left black. Each picture is the same to the byte as the same glass drawn alone.
  {
    double base[3 * MB_INST];
    rect_at(base, 0, 0, W, H, 0, 0.94, 0.94, 0.92, 0);
    rect_at(base + MB_INST, 10, 4, 40, 10, 0, 0.85, 0.20, 0.20, 0);
    rect_at(base + 2 * MB_INST, 10, 60, 60, 10, 0, 0.20, 0.45, 0.90, 0);
    double fl[9 * MB_INST];
    while (glGetError() != GL_NO_ERROR) {
    }

    // (1) Two progressive blurs, the top's and the foot's, against the foot's alone.
    memcpy(fl, base, sizeof base);
    progressive_at(fl + 3 * MB_INST, 0, 22, 1, -50);
    progressive_at(fl + 4 * MB_INST, 53, H, 0, -51);
    glass_forget();
    feedback_loops = 0;
    gl_present(fl, 5, 0.94, 0.94, 0.92);
    CHECK(glGetError() == GL_NO_ERROR);
    CHECK(feedback_loops == 0);
    CHECK(!level_left_bound());
    unsigned char *both = pixels_of_fb(surface);
    // (the next frame, from blurs kept, and drawn anew)
    gl_present(fl, 5, 0.94, 0.94, 0.92);
    CHECK(feedback_loops == 0);
    CHECK(surface_as_fresh(surface));
    CHECK(feedback_loops == 0);
    memcpy(fl + 3 * MB_INST, fl + 4 * MB_INST, MB_INST * sizeof(double));
    glass_forget();
    gl_present(fl, 4, 0.94, 0.94, 0.92);
    unsigned char *alone = pixels_of_fb(surface);
    printf("gles_render: two progressive foot=%.3f alone=%.3f loops=%d\n", luma_at(both, 50, 66), luma_at(alone, 50, 66),
           feedback_loops);
    CHECK(luma_at(both, 50, 66) > 0.5);
    CHECK(foot_same(both, alone, 46 * S));
    free(both);
    free(alone);

    // (2) A progressive blur, then a liquid glass capsule (kind 6) and a frosted glass (kind 5), against those alone.
    double later[2 * MB_INST];
    rect_at(later, 12, 30, 44, 12, 6, 0.99, 0.99, 0.99, -53);
    later[4] = 6.0;
    later[6] = 1.0;
    later[7] = 2.0;
    later[11] = 0x67 / 255.0;
    later[13] = 8.0;
    later[14] = -1.0;
    later[15] = 1.0;
    later[21] = 4.0;
    rect_at(later + MB_INST, 0, 53, W, 22, 5, 0.96, 0.96, 0.96, -52);
    later[MB_INST + 6] = 1.1;
    later[MB_INST + 7] = 4.0;
    later[MB_INST + 11] = 0.35;
    later[MB_INST + 15] = 1.0;
    memcpy(fl, base, sizeof base);
    progressive_at(fl + 3 * MB_INST, 0, 22, 1, -50);
    memcpy(fl + 4 * MB_INST, later, sizeof later);
    glass_forget();
    feedback_loops = 0;
    gl_present(fl, 6, 0.94, 0.94, 0.92);
    CHECK(glGetError() == GL_NO_ERROR);
    CHECK(feedback_loops == 0);
    CHECK(!level_left_bound());
    both = pixels_of_fb(surface);
    gl_present(fl, 6, 0.94, 0.94, 0.92);
    CHECK(feedback_loops == 0);
    CHECK(surface_as_fresh(surface));
    memcpy(fl + 3 * MB_INST, later, sizeof later);
    glass_forget();
    gl_present(fl, 5, 0.94, 0.94, 0.92);
    alone = pixels_of_fb(surface);
    printf("gles_render: progressive then glass capsule=%.3f frost=%.3f loops=%d\n", luma_at(both, 34, 36),
           luma_at(both, 50, 66), feedback_loops);
    CHECK(luma_at(both, 34, 36) > 0.5);
    CHECK(luma_at(both, 50, 66) > 0.5);
    CHECK(foot_same(both, alone, 26 * S));
    free(both);
    free(alone);

    // (3) A progressive blur, then two lenses (kind 8), red and blue under them; the frame again, and anew.
    memcpy(fl, base, sizeof base);
    progressive_at(fl + 3 * MB_INST, 0, 22, 1, -50);
    lens_at(fl + 4 * MB_INST, 5, 30, 1.0, 0.0, 0.0);
    lens_at(fl + 6 * MB_INST, 55, 30, 0.0, 0.0, 1.0);
    glass_forget();
    feedback_loops = 0;
    gl_present(fl, 8, 0.94, 0.94, 0.92);
    CHECK(glGetError() == GL_NO_ERROR);
    CHECK(feedback_loops == 0);
    CHECK(!level_left_bound());
    both = pixels_of_fb(surface);
    gl_present(fl, 8, 0.94, 0.94, 0.92);
    CHECK(glGetError() == GL_NO_ERROR);
    CHECK(feedback_loops == 0);
    alone = pixels_of_fb(surface);
    CHECK(memcmp(both, alone, (size_t)fb_w * fb_h * 4) == 0);
    free(alone);
    CHECK(surface_as_fresh(surface));
    CHECK(feedback_loops == 0);
    const unsigned char *red = both + ((fb_h - 1 - 50 * S) * fb_w + 25 * S) * 4;
    const unsigned char *blue = both + ((fb_h - 1 - 50 * S) * fb_w + 75 * S) * 4;
    printf("gles_render: two lenses red=%d,%d,%d blue=%d,%d,%d loops=%d\n", red[0], red[1], red[2], blue[0], blue[1],
           blue[2], feedback_loops);
    CHECK((int)red[0] - (int)red[2] > 100);
    CHECK((int)blue[2] - (int)blue[0] > 100);
    free(both);
    glass_forget();
  }

  // Progressive blur small-radius anti-ghosting regression: 1pt and 1px dark vertical/horizontal strokes over
  // a light background under blur=8.5, fade_h=68 progressive blur at both 2x and 1x scale must produce strictly
  // unimodal profiles (no 9-tap comb ghosting / secondary dark peaks) and monotonically attenuate center contrast.
  {
    static const int scales[2] = {2, 1};
    static const double v_ramps[6] = {0.06, 0.10, 0.14, 0.18, 0.24, 0.35};
    static const double h_ramps[3] = {0.10, 0.18, 0.24};
    GLuint pb_tex = 0, pb_fb = 0;
    for (int si = 0; si < 2; si++) {
      int sc = scales[si];
      fb_w = W * sc;
      fb_h = H * sc;
      cur_w = W;
      cur_h = H;
      cur_scale = (double)sc;
      if (pb_fb) { glDeleteFramebuffers(1, &pb_fb); pb_fb = 0; }
      if (pb_tex) { glDeleteTextures(1, &pb_tex); pb_tex = 0; }
      glGenTextures(1, &pb_tex);
      glBindTexture(GL_TEXTURE_2D, pb_tex);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
      glGenFramebuffers(1, &pb_fb);
      glBindFramebuffer(GL_FRAMEBUFFER, pb_fb);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, pb_tex, 0);
      CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
      target_fb = pb_fb;
      canvas_ok = 0;

      double widths[2] = {1.0, 1.0 / (double)sc};
      int n_widths = (sc > 1) ? 2 : 1;
      for (int wi = 0; wi < n_widths; wi++) {
        double lw = widths[wi];
        // 1) Vertical stroke across the entire fade band (y=0..75)
        double pb[3 * MB_INST];
        rect_at(pb, 0, 0, W, H, 0, 0.96, 0.96, 0.96, 0);
        rect_at(pb + MB_INST, 50.0, 0.0, lw, H, 0, 0.05, 0.05, 0.05, 0);
        rect_at(pb + 2 * MB_INST, 0, 0, W, 68.0, 5, 0.96, 0.96, 0.96, -40);
        pb[2 * MB_INST + 6] = 1.0;
        pb[2 * MB_INST + 7] = 8.5;
        pb[2 * MB_INST + 11] = 0.15;
        pb[2 * MB_INST + 15] = 1.0;
        pb[2 * MB_INST + 22] = -1.0;
        pb[2 * MB_INST + 54] = 68.0;
        pb[2 * MB_INST + 55] = 68.0;
        glass_forget();
        gl_present(pb, 3, 0.96, 0.96, 0.96);
        unsigned char *px = pixels_of_fb(pb_fb);
        int prev_center = -1;
        int first_center = -1;
        int last_center = -1;
        int mono_ok = 1;
        int max_dip = 0;
        for (int ri = 0; ri < 6; ri++) {
          int py = (int)llround(68.0 * (1.0 - v_ramps[ri]) * (double)sc);
          if (py < 0) py = 0;
          if (py >= fb_h) py = fb_h - 1;
          int row = fb_h - 1 - py;
          int x0 = (int)floor(50.0 * (double)sc) - 2;
          int x1 = (int)ceil((50.0 + lw) * (double)sc) + 2;
          int xc = x0, min_l = 256;
          for (int x = x0; x <= x1; x++) {
            int l = px[(row * fb_w + x) * 4 + 1];
            if (l < min_l) { min_l = l; xc = x; }
          }
          if (ri == 0) first_center = min_l;
          last_center = min_l;
          if (prev_center >= 0 && min_l < prev_center - 2) {
            fprintf(stderr, "gles_render: prog-blur v-stroke center non-mono sc=%d lw=%.2f ramp=%.2f prev=%d cur=%d\n",
                    sc, lw, v_ramps[ri], prev_center, min_l);
            mono_ok = 0;
          }
          prev_center = min_l;
          for (int dir = -1; dir <= 1; dir += 2) {
            int max_seen = min_l;
            for (int dx = 1; dx <= 12; dx++) {
              int x = xc + dir * dx;
              if (x < 0 || x >= fb_w) break;
              int l = px[(row * fb_w + x) * 4 + 1];
              if (max_seen - l > max_dip) max_dip = max_seen - l;
              if (l < max_seen - 2) mono_ok = 0;
              if (l > max_seen) max_seen = l;
            }
          }
        }
        printf("gles_render: prog-blur v-stroke sc=%d lw=%.2f first=%d last=%d max_dip=%d\n",
               sc, lw, first_center, last_center, max_dip);
        CHECK(mono_ok);
        CHECK(last_center > first_center + 15);
        free(px);

        // 2) Horizontal strokes at representative small-radius ramps
        int h_mono_ok = 1;
        int h_max_dip = 0;
        for (int ri = 0; ri < 3; ri++) {
          double y_pt = 68.0 * (1.0 - h_ramps[ri]);
          double hp[3 * MB_INST];
          rect_at(hp, 0, 0, W, H, 0, 0.96, 0.96, 0.96, 0);
          rect_at(hp + MB_INST, 10.0, y_pt, 80.0, lw, 0, 0.05, 0.05, 0.05, 0);
          rect_at(hp + 2 * MB_INST, 0, 0, W, 68.0, 5, 0.96, 0.96, 0.96, -41);
          hp[2 * MB_INST + 6] = 1.0;
          hp[2 * MB_INST + 7] = 8.5;
          hp[2 * MB_INST + 11] = 0.15;
          hp[2 * MB_INST + 15] = 1.0;
          hp[2 * MB_INST + 22] = -1.0;
          hp[2 * MB_INST + 54] = 68.0;
          hp[2 * MB_INST + 55] = 68.0;
          glass_forget();
          gl_present(hp, 3, 0.96, 0.96, 0.96);
          unsigned char *hpx = pixels_of_fb(pb_fb);
          int px_x = 50 * sc;
          int y0 = (int)floor(y_pt * (double)sc) - 2;
          int y1 = (int)ceil((y_pt + lw) * (double)sc) + 2;
          int yc = y0, min_l = 256;
          for (int y = y0; y <= y1; y++) {
            int row = fb_h - 1 - y;
            int l = hpx[(row * fb_w + px_x) * 4 + 1];
            if (l < min_l) { min_l = l; yc = y; }
          }
          for (int dir = -1; dir <= 1; dir += 2) {
            int max_seen = min_l;
            for (int dy = 1; dy <= 10; dy++) {
              int y = yc + dir * dy;
              if (y < 0 || y >= fb_h) break;
              int row = fb_h - 1 - y;
              int l = hpx[(row * fb_w + px_x) * 4 + 1];
              if (max_seen - l > h_max_dip) h_max_dip = max_seen - l;
              if (l < max_seen - 2) h_mono_ok = 0;
              if (l > max_seen) max_seen = l;
            }
          }
          free(hpx);
        }
        printf("gles_render: prog-blur h-stroke sc=%d lw=%.2f max_dip=%d\n", sc, lw, h_max_dip);
        CHECK(h_mono_ok);
      }
    }
    if (pb_fb) glDeleteFramebuffers(1, &pb_fb);
    if (pb_tex) glDeleteTextures(1, &pb_tex);
    fb_w = W * S;
    fb_h = H * S;
    cur_w = W;
    cur_h = H;
    cur_scale = S;
    target_fb = surface;
    glBindFramebuffer(GL_FRAMEBUFFER, surface);
    canvas_ok = 0;
    glass_forget();
  }

  // Perf-30: (1) Rotated spinner isolation & 60-frame benchmark, (2) 45-deg grazing & far-pivot rotated overlap,
  // (3) unrelated kind==12 vector segment isolation, (4) GLES VRAM budget + compact 64px slots + high-water lv shrink.
  {
    GLuint p30_tex = 0, p30_fb = 0;
    int pw = 400, ph = 600, psc = 2;
    fb_w = pw * psc;
    fb_h = ph * psc;
    cur_w = pw;
    cur_h = ph;
    cur_scale = psc;
    glGenTextures(1, &p30_tex);
    glBindTexture(GL_TEXTURE_2D, p30_tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
    glGenFramebuffers(1, &p30_fb);
    glBindFramebuffer(GL_FRAMEBUFFER, p30_fb);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, p30_tex, 0);
    CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
    target_fb = p30_fb;
    canvas_ok = 0;
    glass_free();

    // (1) Rotated spinner 400pt below top progressive blur + liquid glass: 60 frames, frames 2..60 must have 0 blurs.
    {
      double sp[5 * MB_INST];
      rect_at(sp, 0, 0, pw, ph, 0, 0.94, 0.94, 0.92, 0);
      sp[18] = pw; sp[19] = ph;
      rect_at(sp + 1 * MB_INST, 20, 8, 120, 24, 0, 0.85, 0.20, 0.20, 0);
      sp[1 * MB_INST + 18] = pw; sp[1 * MB_INST + 19] = ph;
      // Rotating spinner far below (y=460, 400pt below top glass)
      rect_at(sp + 2 * MB_INST, 180, 460, 20, 20, 0, 0.20, 0.45, 0.90, 0);
      sp[2 * MB_INST + 18] = pw; sp[2 * MB_INST + 19] = ph;
      sp[2 * MB_INST + 32] = 0.1;
      sp[2 * MB_INST + 33] = 190.0;
      sp[2 * MB_INST + 34] = 470.0;
      // Top progressive blur
      rect_at(sp + 3 * MB_INST, 0, 0, pw, 64, 5, 0.96, 0.96, 0.96, -50);
      sp[3 * MB_INST + 6] = 1.1;
      sp[3 * MB_INST + 7] = 6.0;
      sp[3 * MB_INST + 11] = 0.35;
      sp[3 * MB_INST + 15] = 1.0;
      sp[3 * MB_INST + 18] = pw; sp[3 * MB_INST + 19] = ph;
      sp[3 * MB_INST + 22] = -1.0;
      sp[3 * MB_INST + 54] = 64.0;
      sp[3 * MB_INST + 55] = 24.0;
      // Top liquid glass capsule
      rect_at(sp + 4 * MB_INST, 24, 12, 140, 32, 6, 0.99, 0.99, 0.99, -51);
      sp[4 * MB_INST + 4] = 16.0;
      sp[4 * MB_INST + 6] = 1.0;
      sp[4 * MB_INST + 7] = 2.0;
      sp[4 * MB_INST + 11] = 0x67 / 255.0;
      sp[4 * MB_INST + 13] = 8.0;
      sp[4 * MB_INST + 14] = -1.0;
      sp[4 * MB_INST + 15] = 1.0;
      sp[4 * MB_INST + 18] = pw; sp[4 * MB_INST + 19] = ph;
      sp[4 * MB_INST + 21] = 6.0;

      glass_forget();
      gl_set_fixed_dt(1.0 / 60.0);
      int b_start = blurs_made;
      int steady_blurs = 0;
      struct timespec t0, t1;
      clock_gettime(CLOCK_MONOTONIC, &t0);
      for (int frame = 0; frame < 60; frame++) {
        sp[2 * MB_INST + 32] = 0.1 + frame * 0.105;
        int b_before = blurs_made;
        gl_present(sp, 5, 0.94, 0.94, 0.92);
        if (frame == 0) {
          CHECK(blurs_made == b_before + 2);
        } else {
          steady_blurs += (blurs_made - b_before);
          CHECK(blurs_made == b_before);
        }
      }
      glFinish();
      clock_gettime(CLOCK_MONOTONIC, &t1);
      double elapsed_ms = (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
      printf("gles_render: Perf-30 60-frame spinner blurs=%d (frames 2..60=%d) ms=%.2f\n",
             blurs_made - b_start, steady_blurs, elapsed_ms);
      CHECK(steady_blurs == 0);
      CHECK(surface_as_whole(p30_fb));
      CHECK(surface_as_fresh(p30_fb));
      gl_set_fixed_dt(0.0);
    }

    // (2) Rotated instance grazing overlap at 45 deg + far-pivot swing into glass capture region.
    {
      double rg[3 * MB_INST];
      rect_at(rg, 0, 0, pw, ph, 0, 0.94, 0.94, 0.92, 0);
      rg[18] = pw; rg[19] = ph;
      // Glass at y=0..60 with blur=4.0 (margin = 14pt -> grab reaches y=74)
      // Rect 40x40 centered at (100, 100): at angle=0, top is y=80 (> 74, outside).
      // At angle=45 deg, half-diagonal is 20*sqrt(2) = 28.28 -> top reaches y=71.72 (< 74, overlaps grab!).
      rect_at(rg + 1 * MB_INST, 80, 80, 40, 40, 0, 0.90, 0.15, 0.15, 0);
      rg[1 * MB_INST + 18] = pw; rg[1 * MB_INST + 19] = ph;
      rg[1 * MB_INST + 32] = 0.0;
      rg[1 * MB_INST + 33] = 100.0;
      rg[1 * MB_INST + 34] = 100.0;
      rect_at(rg + 2 * MB_INST, 40, 20, 120, 40, 5, 0.98, 0.98, 0.98, -52);
      rg[2 * MB_INST + 7] = 4.0;
      rg[2 * MB_INST + 11] = 0.45;
      rg[2 * MB_INST + 18] = pw; rg[2 * MB_INST + 19] = ph;

      glass_forget();
      gl_present(rg, 3, 0.94, 0.94, 0.92);
      CHECK(surface_as_whole(p30_fb));
      // Rotate to 45 deg: corner grazes glass capture -> must rebuild and match fresh render byte-for-byte
      rg[1 * MB_INST + 32] = 0.7853981633974483;
      int b0 = blurs_made;
      gl_present(rg, 3, 0.94, 0.94, 0.92);
      CHECK(blurs_made == b0 + 1);
      CHECK(surface_as_fresh(p30_fb));

      // Far-pivot swing: rect at (200, 300, 30, 30), pivot at (150, 170), rotate by PI -> lands near (85, 25) inside glass!
      rg[1 * MB_INST + 0] = 200.0; rg[1 * MB_INST + 1] = 300.0;
      rg[1 * MB_INST + 2] = 30.0; rg[1 * MB_INST + 3] = 30.0;
      rg[1 * MB_INST + 32] = 0.0;
      rg[1 * MB_INST + 33] = 150.0; rg[1 * MB_INST + 34] = 170.0;
      glass_forget();
      gl_present(rg, 3, 0.94, 0.94, 0.92);
      rg[1 * MB_INST + 32] = 3.141592653589793;
      b0 = blurs_made;
      gl_present(rg, 3, 0.94, 0.94, 0.92);
      CHECK(blurs_made == b0 + 1);
      CHECK(surface_as_fresh(p30_fb));
    }

    // (3) Unrelated kind==12 vector path segment isolation.
    {
      double vg[4 * MB_INST];
      rect_at(vg, 0, 0, pw, ph, 0, 0.94, 0.94, 0.92, 0);
      vg[18] = pw; vg[19] = ph;
      // Bottom kind==11 vector shape (y=400..440, far below top glass)
      rect_at(vg + 1 * MB_INST, 40, 400, 60, 40, 11, 0.10, 0.30, 0.85, 0);
      vg[1 * MB_INST + 12] = 0.0;  // seg start
      vg[1 * MB_INST + 13] = 1.0;  // seg count
      vg[1 * MB_INST + 18] = pw; vg[1 * MB_INST + 19] = ph;
      // Top frosted glass (y=20..60, no kind==11 under it)
      rect_at(vg + 2 * MB_INST, 20, 20, 140, 40, 5, 0.98, 0.98, 0.98, -53);
      vg[2 * MB_INST + 7] = 4.0;
      vg[2 * MB_INST + 11] = 0.45;
      vg[2 * MB_INST + 18] = pw; vg[2 * MB_INST + 19] = ph;
      // Trailing kind==12 segment piece
      memset(vg + 3 * MB_INST, 0, MB_INST * sizeof(double));
      vg[3 * MB_INST + 5] = 12;
      vg[3 * MB_INST + 0] = 40; vg[3 * MB_INST + 1] = 400;
      vg[3 * MB_INST + 2] = 100; vg[3 * MB_INST + 3] = 440;

      glass_forget();
      int b0 = blurs_made;
      gl_present(vg, 4, 0.94, 0.94, 0.92);
      CHECK(blurs_made == b0 + 1);
      for (int step = 0; step < 3; step++) {
        vg[3 * MB_INST + 2] = 90 + step * 5;
        b0 = blurs_made;
        gl_present(vg, 4, 0.94, 0.94, 0.92);
        CHECK(blurs_made == b0);
        CHECK(surface_as_whole(p30_fb));
      }
      CHECK(surface_as_fresh(p30_fb));

      // Move kind==11 under the top glass: mutating kind==12 MUST rebuild blur!
      vg[1 * MB_INST + 1] = 24.0;
      vg[3 * MB_INST + 1] = 24.0; vg[3 * MB_INST + 3] = 56.0;
      glass_forget();
      gl_present(vg, 4, 0.94, 0.94, 0.92);
      vg[3 * MB_INST + 2] = 110.0;
      b0 = blurs_made;
      gl_present(vg, 4, 0.94, 0.94, 0.92);
      CHECK(blurs_made == b0 + 1);
      CHECK(surface_as_fresh(p30_fb));
    }

    // (4) GLES VRAM budget + compact 64px slot textures + high-water lv_w/lv_h shrink.
    {
      GLuint big_tex = 0, big_fb = 0;
      int bw_pt = 1280, bh_pt = 720, bsc = 2;
      fb_w = bw_pt * bsc;
      fb_h = bh_pt * bsc;
      cur_w = bw_pt;
      cur_h = bh_pt;
      cur_scale = bsc;
      glGenTextures(1, &big_tex);
      glBindTexture(GL_TEXTURE_2D, big_tex);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
      glGenFramebuffers(1, &big_fb);
      glBindFramebuffer(GL_FRAMEBUFFER, big_fb);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, big_tex, 0);
      CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
      target_fb = big_fb;
      canvas_ok = 0;
      glass_free();

      double big[3 * MB_INST];
      rect_at(big, 0, 0, bw_pt, bh_pt, 0, 0.12, 0.16, 0.22, 0);
      big[18] = bw_pt; big[19] = bh_pt;
      rect_at(big + MB_INST, 0, 0, 1240, 60, 5, 1, 1, 1, -54);
      big[MB_INST + 7] = 12.0;
      big[MB_INST + 11] = 0.4;
      big[MB_INST + 18] = bw_pt; big[MB_INST + 19] = bh_pt;
      big[MB_INST + 22] = -1.0;
      big[MB_INST + 54] = 60.0;
      big[MB_INST + 55] = 30.0;
      rect_at(big + 2 * MB_INST, 0, 80, 120, 620, 5, 1, 1, 1, -55);
      big[2 * MB_INST + 7] = 12.0;
      big[2 * MB_INST + 11] = 0.4;
      big[2 * MB_INST + 18] = bw_pt; big[2 * MB_INST + 19] = bh_pt;
      gl_present(big, 3, 0.12, 0.16, 0.22);
      CHECK(lv_w >= 2400 && lv_h >= 1200);
      CHECK(slots_total_bytes() <= MB_GLASS_CACHE_MAX_BYTES);
      CHECK(surface_as_whole(big_fb));

      double sm[4 * MB_INST];
      rect_at(sm, 0, 0, bw_pt, bh_pt, 0, 0.14, 0.18, 0.24, 0);
      sm[18] = bw_pt; sm[19] = bh_pt;
      rect_at(sm + MB_INST, 20, 30, 420, 60, 0, 0.90, 0.35, 0.20, 0);
      sm[MB_INST + 18] = bw_pt; sm[MB_INST + 19] = bh_pt;
      rect_at(sm + 2 * MB_INST, 40, 40, 160, 44, 5, 1, 1, 1, -56);
      sm[2 * MB_INST + 7] = 12.0;
      sm[2 * MB_INST + 11] = 0.45;
      sm[2 * MB_INST + 18] = bw_pt; sm[2 * MB_INST + 19] = bh_pt;
      sm[2 * MB_INST + 22] = -1.0;
      sm[2 * MB_INST + 54] = 84.0;
      sm[2 * MB_INST + 55] = 44.0;
      rect_at(sm + 3 * MB_INST, 300, 40, 120, 40, 5, 1, 1, 1, -57);
      sm[3 * MB_INST + 7] = 3.0;
      sm[3 * MB_INST + 11] = 0.45;
      sm[3 * MB_INST + 18] = bw_pt; sm[3 * MB_INST + 19] = bh_pt;

      size_t peak_slot_bytes = slots_total_bytes();
      size_t max_small_tex_area = 0;
      for (int step = 0; step < 40; step++) {
        sm[MB_INST + 0] = 20 + (step * 7) % 120;
        gl_present(sm, 4, 0.14, 0.18, 0.24);
        size_t cur_bytes = slots_total_bytes();
        if (cur_bytes > peak_slot_bytes) peak_slot_bytes = cur_bytes;
        CHECK(cur_bytes <= MB_GLASS_CACHE_MAX_BYTES);
        for (int j = 0; j < MB_GLASS_SLOTS; j++) {
          if (slots[j].valid && slots[j].bt && slots[j].grab.w < 1000) {
            size_t area = (size_t)slots[j].bw * (size_t)slots[j].bh;
            if (area > max_small_tex_area) max_small_tex_area = area;
          }
        }
      }
      printf("gles_render: glass stress peak_slot_bytes=%zu (limit=%zu) max_small_area=%zu lv_area=%zu\n",
             peak_slot_bytes, (size_t)MB_GLASS_CACHE_MAX_BYTES, max_small_tex_area, (size_t)lv_w * (size_t)lv_h);
      CHECK(peak_slot_bytes <= MB_GLASS_CACHE_MAX_BYTES);
      CHECK(max_small_tex_area > 0 && max_small_tex_area * 8 < (size_t)lv_w * (size_t)lv_h);
      CHECK(surface_as_whole(big_fb));
      CHECK(surface_as_fresh(big_fb));

      // High-water mark shrink over MB_GLASS_IDLE (180) frames
      glass_free();
      fb_w = 400 * 2;
      fb_h = 300 * 2;
      cur_w = 400;
      cur_h = 300;
      cur_scale = 2;
      target_fb = p30_fb;
      glBindFramebuffer(GL_FRAMEBUFFER, p30_fb);
      // Reuse a 800x600 FBO for clean 400x300@2x shrink test
      glDeleteFramebuffers(1, &big_fb);
      glDeleteTextures(1, &big_tex);
      glGenTextures(1, &big_tex);
      glBindTexture(GL_TEXTURE_2D, big_tex);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
      glGenFramebuffers(1, &big_fb);
      glBindFramebuffer(GL_FRAMEBUFFER, big_fb);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, big_tex, 0);
      target_fb = big_fb;
      canvas_ok = 0;

      double lg[2 * MB_INST];
      rect_at(lg, 0, 0, 400, 300, 0, 0.15, 0.25, 0.40, 0);
      lg[18] = 400; lg[19] = 300;
      rect_at(lg + MB_INST, 0, 0, 400, 300, 5, 1, 1, 1, -58);
      lg[MB_INST + 7] = 8.0;
      lg[MB_INST + 11] = 0.45;
      lg[MB_INST + 18] = 400; lg[MB_INST + 19] = 300;
      gl_present(lg, 2, 0.15, 0.25, 0.40);
      size_t big_lv_area = (size_t)lv_w * (size_t)lv_h;
      CHECK(lv_w == 800 && lv_h == 600);
      CHECK(surface_as_whole(big_fb));

      double sml[3 * MB_INST];
      rect_at(sml, 0, 0, 400, 300, 0, 0.15, 0.25, 0.40, 0);
      sml[18] = 400; sml[19] = 300;
      rect_at(sml + MB_INST, 24, 24, 52, 32, 0, 0.90, 0.20, 0.20, 0);
      sml[MB_INST + 18] = 400; sml[MB_INST + 19] = 300;
      rect_at(sml + 2 * MB_INST, 20, 20, 60, 40, 5, 1, 1, 1, -59);
      sml[2 * MB_INST + 7] = 4.0;
      sml[2 * MB_INST + 11] = 0.45;
      sml[2 * MB_INST + 18] = 400; sml[2 * MB_INST + 19] = 300;
      for (int i = 0; i < MB_GLASS_IDLE; i++) {
        sml[MB_INST + 0] = 24 + (i % 20);
        gl_present(sml, 3, 0.15, 0.25, 0.40);
      }
      size_t shrunk_lv_area = (size_t)lv_w * (size_t)lv_h;
      printf("gles_render: lv shrink big_area=%zu -> shrunk_area=%zu (%dx%d)\n",
             big_lv_area, shrunk_lv_area, lv_w, lv_h);
      CHECK(shrunk_lv_area * 4 < big_lv_area);
      CHECK(surface_as_whole(big_fb));
      CHECK(surface_as_fresh(big_fb));

      glDeleteFramebuffers(1, &big_fb);
      glDeleteTextures(1, &big_tex);
    }

    // (5) Perf-31: multi-dirty-rect partial redraw de-amplification (single VBO upload, grab_in_cut skip,
    //     kind 8 lens skip, conservative CPU scissor culling for non-glass runs, byte-for-byte parity).
    {
      int pw_pt = 400, ph_pt = 600, psc = 2;
      fb_w = pw_pt * psc;
      fb_h = ph_pt * psc;
      cur_w = pw_pt;
      cur_h = ph_pt;
      cur_scale = psc;
      target_fb = p30_fb;
      glBindFramebuffer(GL_FRAMEBUFFER, p30_fb);
      canvas_ok = 0;
      glass_free();

      // Build a rich scene: 400 grid rects + 1 shadow + 1 clipped/oclipped rect + 1 rotated rect +
      // 2 frosted glass groups (top y=10..50, bottom y=540..580) + 1 foreground lens (kind 8 + 2 children at y=280..320).
      const int GRID_N = 400;
      const int TOTAL = GRID_N + 8;
      double *sc = (double *)calloc((size_t)TOTAL * MB_INST, sizeof(double));
      for (int i = 0; i < GRID_N; i++) {
        int col = i % 20, row = i / 20;
        double x = 8.0 + col * 19.0;
        double y = 60.0 + row * 23.0;
        rect_at(sc + (size_t)i * MB_INST, x, y, 14.0, 16.0, 0,
                0.2 + 0.03 * col, 0.25 + 0.03 * row, 0.55, 0);
        sc[(size_t)i * MB_INST + 18] = pw_pt;
        sc[(size_t)i * MB_INST + 19] = ph_pt;
      }
      int idx = GRID_N;
      // Shadow (kind 2) near (26, 100)
      rect_at(sc + (size_t)idx * MB_INST, 26, 100, 24, 20, 2, 0.0, 0.0, 0.0, 0);
      sc[(size_t)idx * MB_INST + 7] = 6.0;
      sc[(size_t)idx * MB_INST + 11] = 0.45;
      sc[(size_t)idx * MB_INST + 18] = pw_pt; sc[(size_t)idx * MB_INST + 19] = ph_pt;
      idx++;
      // Clipped + outer-clipped rect (active a_orc -> a_oclip clips it inside [300, 440] x [340, 470])
      rect_at(sc + (size_t)idx * MB_INST, 290, 430, 60, 50, 0, 0.85, 0.25, 0.15, 0);
      sc[(size_t)idx * MB_INST + 16] = 295; sc[(size_t)idx * MB_INST + 17] = 435;
      sc[(size_t)idx * MB_INST + 18] = 345; sc[(size_t)idx * MB_INST + 19] = 475;
      sc[(size_t)idx * MB_INST + 40] = 300; sc[(size_t)idx * MB_INST + 41] = 440;
      sc[(size_t)idx * MB_INST + 42] = 340; sc[(size_t)idx * MB_INST + 43] = 470;
      sc[(size_t)idx * MB_INST + 44] = 6.0; sc[(size_t)idx * MB_INST + 45] = 6.0;
      sc[(size_t)idx * MB_INST + 46] = 6.0; sc[(size_t)idx * MB_INST + 47] = 6.0;
      idx++;
      // Rotated rect near (190, 150)
      rect_at(sc + (size_t)idx * MB_INST, 180, 140, 26, 26, 0, 0.15, 0.80, 0.35, 0);
      sc[(size_t)idx * MB_INST + 18] = pw_pt; sc[(size_t)idx * MB_INST + 19] = ph_pt;
      sc[(size_t)idx * MB_INST + 32] = 0.6;
      sc[(size_t)idx * MB_INST + 33] = 193.0;
      sc[(size_t)idx * MB_INST + 34] = 153.0;
      idx++;
      // Glass group 1 at top (y=10..50)
      rect_at(sc + (size_t)idx * MB_INST, 20, 10, 360, 40, 5, 0.96, 0.96, 0.96, -71);
      sc[(size_t)idx * MB_INST + 7] = 6.0;
      sc[(size_t)idx * MB_INST + 11] = 0.45;
      sc[(size_t)idx * MB_INST + 18] = pw_pt; sc[(size_t)idx * MB_INST + 19] = ph_pt;
      idx++;
      // Glass group 2 at bottom (y=540..580)
      rect_at(sc + (size_t)idx * MB_INST, 20, 540, 360, 40, 5, 0.96, 0.96, 0.96, -72);
      sc[(size_t)idx * MB_INST + 7] = 6.0;
      sc[(size_t)idx * MB_INST + 11] = 0.45;
      sc[(size_t)idx * MB_INST + 18] = pw_pt; sc[(size_t)idx * MB_INST + 19] = ph_pt;
      idx++;
      // Foreground lens (kind 8) with 2 children at (140, 280, 120, 40)
      rect_at(sc + (size_t)idx * MB_INST, 140, 280, 120, 40, 8, 1.0, 1.0, 1.0, 0);
      sc[(size_t)idx * MB_INST + 4] = 12.0;
      sc[(size_t)idx * MB_INST + 7] = 2.0;
      sc[(size_t)idx * MB_INST + 11] = 1.0;
      sc[(size_t)idx * MB_INST + 12] = 2.0; // child_n = 2
      sc[(size_t)idx * MB_INST + 14] = 4.0;
      sc[(size_t)idx * MB_INST + 18] = pw_pt; sc[(size_t)idx * MB_INST + 19] = ph_pt;
      idx++;
      rect_at(sc + (size_t)idx * MB_INST, 150, 288, 40, 24, 0, 0.90, 0.30, 0.20, 0);
      sc[(size_t)idx * MB_INST + 18] = pw_pt; sc[(size_t)idx * MB_INST + 19] = ph_pt;
      idx++;
      rect_at(sc + (size_t)idx * MB_INST, 200, 288, 45, 24, 0, 0.20, 0.45, 0.90, 0);
      sc[(size_t)idx * MB_INST + 18] = pw_pt; sc[(size_t)idx * MB_INST + 19] = ph_pt;
      idx++;
      CHECK(idx == TOTAL);

      // Whole frame first (primes canvas_ok = 1 via dirty whole).
      mb_host_render_dirty(0, 0, pw_pt, ph_pt);
      gl_present(sc, TOTAL, 0.92, 0.93, 0.95);
      CHECK(surface_as_whole(p30_fb));
      CHECK(surface_as_fresh(p30_fb));

      // Case A: 4 small disjoint dirty rects away from both glass groups and the lens.
      // Invalidate glass slots to prove neither off-rect glass group triggers capture()/blur().
      slots_invalidate();
      sc[21 * MB_INST + 8] = 0.95; // near (27, 83)
      sc[88 * MB_INST + 9] = 0.90; // near (160, 152)
      sc[310 * MB_INST + 10] = 0.10; // near (198, 405)
      sc[(GRID_N + 1) * MB_INST + 9] = 0.85; // oclipped rect at (300..340, 440..470)
      int vbo0 = vbo_uploads, blurs0 = blurs_made, draws0 = instanced_draws, inst0 = instanced_total;
      mb_host_render_dirty(8, 78, 56, 52);      // covers shadow + rect 21 (clear of top glass y<=70)
      mb_host_render_dirty(155, 130, 60, 50);   // covers rotated rect + rect 88
      mb_host_render_dirty(190, 398, 30, 30);   // covers rect 310
      mb_host_render_dirty(292, 432, 56, 46);   // covers oclipped rect
      gl_present(sc, TOTAL, 0.92, 0.93, 0.95);
      int vbo_d = vbo_uploads - vbo0;
      int blurs_d = blurs_made - blurs0;
      int draws_d = instanced_draws - draws0;
      int inst_d = instanced_total - inst0;
      printf("gles_render: Perf-31 4-rect partial: vbo_uploads=%d blurs=%d draws=%d inst_submitted=%d (unculled=%d)\n",
             vbo_d, blurs_d, draws_d, inst_d, 4 * TOTAL);
      CHECK(vbo_d == 1);
      CHECK(blurs_d == 0);
      CHECK(inst_d < TOTAL); // <25% of 4*TOTAL
      CHECK(surface_as_whole(p30_fb));
      CHECK(surface_as_fresh(p30_fb));

      // Case B: 2 dirty rects, one covering top glass + one covering the kind 8 lens; bottom glass remains untouched.
      slots_invalidate();
      sc[(GRID_N + 6) * MB_INST + 8] = 0.15; // lens child 1 color change
      sc[0 * MB_INST + 8] = 0.95;            // rect near top glass
      vbo0 = vbo_uploads;
      blurs0 = blurs_made;
      mb_host_render_dirty(0, 0, 400, 80);    // covers top glass
      mb_host_render_dirty(120, 260, 160, 80); // covers kind 8 lens
      gl_present(sc, TOTAL, 0.92, 0.93, 0.95);
      CHECK(vbo_uploads - vbo0 == 1);
      CHECK(blurs_made - blurs0 == 1); // only top glass blurred, bottom glass skipped!
      CHECK(surface_as_whole(p30_fb));
      CHECK(surface_as_fresh(p30_fb));

      free(sc);
    }

    glDeleteFramebuffers(1, &p30_fb);
    glDeleteTextures(1, &p30_tex);
    fb_w = W * S;
    fb_h = H * S;
    cur_w = W;
    cur_h = H;
    cur_scale = S;
    target_fb = surface;
    glBindFramebuffer(GL_FRAMEBUFFER, surface);
    canvas_ok = 0;
    glass_free();
  }

  // Verify every specialized ONE_KIND (-1, 0..11, 13) and auxiliary program (prog_flat, post, ad_prog) compiles and links cleanly.
  {
    while (glGetError() != GL_NO_ERROR) {
    }
    for (int k = 0; k <= MB_KINDS; k++) {
      if (k != MB_KINDS && !has_own_prog(k)) continue;
      use_prog(k == MB_KINDS ? -1 : k);
      GLint linked = 0;
      CHECK(progs[k].p != 0);
      glGetProgramiv(progs[k].p, GL_LINK_STATUS, &linked);
      if (linked != GL_TRUE) {
        char log[1024];
        glGetProgramInfoLog(progs[k].p, sizeof log, NULL, log);
        fprintf(stderr, "gles_render: program kind %d link failed: %s\n", k == MB_KINDS ? -1 : k, log);
      }
      CHECK(linked == GL_TRUE);
    }
    ensure_prog_flat();
    ensure_post();
    ensure_ad_prog();
    GLuint aux[3] = {prog_flat, post, ad_prog};
    for (int i = 0; i < 3; i++) {
      GLint linked = 0;
      CHECK(aux[i] != 0);
      glGetProgramiv(aux[i], GL_LINK_STATUS, &linked);
      CHECK(linked == GL_TRUE);
    }
    CHECK(glGetError() == GL_NO_ERROR);
  }

  if (!failed) printf("gles_render: ok\n");
  return failed;
}
