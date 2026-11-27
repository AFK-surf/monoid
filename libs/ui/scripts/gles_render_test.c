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
#define MB_VIEWS_UNDER 1
static GLuint picture_one;
static GLuint test_under_white_tex;
static int test_under_tid;
static int view_under(int tid) { return test_under_tid && tid == test_under_tid; }
static GLuint image_tex(int id) {
  if (id > MB_VIEW_TEX && view_under(id)) {
    if (!test_under_white_tex) {
      static const uint8_t white[4] = {255, 255, 255, 255};
      glGenTextures(1, &test_under_white_tex);
      glBindTexture(GL_TEXTURE_2D, test_under_white_tex);
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, white);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    }
    return test_under_white_tex;
  }
  return id == 1 ? picture_one : 0;
}
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
static size_t vbo_upload_bytes;
static int fb_blits;
static int instanced_draws;
static int instanced_total;
static int program_binds;
static void checked_buffer_data(GLenum target, GLsizeiptr size, const void *data, GLenum usage) {
  if (target == GL_ARRAY_BUFFER) {
    vbo_uploads++;
    vbo_upload_bytes += (size_t)size;
  }
  epoxy_glBufferData(target, size, data, usage);
}
static void checked_blit_fb(GLint sx0, GLint sy0, GLint sx1, GLint sy1, GLint dx0, GLint dy0, GLint dx1, GLint dy1,
                            GLbitfield mask, GLenum filter) {
  fb_blits++;
  epoxy_glBlitFramebuffer(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, mask, filter);
}
static void checked_use_program(GLuint p) {
  program_binds++;
  epoxy_glUseProgram(p);
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
#undef glBlitFramebuffer
#define glBlitFramebuffer checked_blit_fb
#undef glUseProgram
#define glUseProgram checked_use_program
#undef glDrawArrays
#define glDrawArrays checked_draw_arrays
#undef glDrawArraysInstanced
#define glDrawArraysInstanced checked_draw_arrays_instanced

// Programs made ahead (gles_render.h gl_progs_ahead): the host's thread stood in for by this one, in its own context,
// called by the test where a host would start it
#define MB_PROGS_AHEAD 1
#include "gles_render.h"
#include "frame_mail.h"

static unsigned ahead_started, ahead_started_gen;
static void progs_ahead_start(unsigned gen) {
  ahead_started++;
  ahead_started_gen = gen;
}

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
// slot 23 of bare adaptive text: the whole text's half width and height (ui's bare_text_ink), its centre in 21-22
static double bare_ink(double hw, double hh) { return -(floor(hw) * 4096.0 + floor(hh)); }

static double wcag_luma_u8(int r, int g, int b) {
  double c[3] = {r / 255.0, g / 255.0, b / 255.0};
  for (int i = 0; i < 3; i++) c[i] = c[i] <= 0.04045 ? (c[i] / 12.92) : pow((c[i] + 0.055) / 1.055, 2.4);
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

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

// A shot's pixels (mb_render_pixels_of) in bytes of MoonBit's (their length in the header before them), for
// glass_reflect_cases.h.
static uint8_t *gr_pixels(const double *inst, int n, double r, double g, double b, int w, int h) {
  size_t bytes = (size_t)w * h * 4;
  struct moonbit_object *o = calloc(1, sizeof *o + bytes);
  o->meta = (uint32_t)bytes;
  uint8_t *px = (uint8_t *)(o + 1);
  if (!mb_render_pixels_of(inst, n, r, g, b, 2.0, w, h, px)) {
    free(o);
    return NULL;
  }
  return px;
}
static void gr_free(uint8_t *px) {
  if (px) free((struct moonbit_object *)px - 1);
}
#define GR_KEYS_CHECKED 1
#define GR_HOT_FRAMES 1
#include "glass_reflect_cases.h"

static unsigned char *pixels_of_fb(GLuint fb);

// A frame of glass_reflect_cases.h's hot-frame case drawn as the window draws it (onto the surface, target_fb, read
// back from the top row).
static uint8_t *gr_window_frame(const double *inst, int n_inst, const double bg[3], const double (*rects)[4], int n) {
  if (!n) glass_forget();
  for (int i = 0; i < n; i++) mb_host_render_dirty(rects[i][0], rects[i][1], rects[i][2], rects[i][3]);
  gl_present(inst, n_inst, bg[0], bg[1], bg[2]);
  unsigned char *px = pixels_of_fb(target_fb);
  size_t row = (size_t)fb_w * 4, bytes = row * fb_h;
  struct moonbit_object *o = calloc(1, sizeof *o + bytes);
  uint8_t *out = (uint8_t *)(o + 1);
  for (int k = 0; k < fb_h; k++) memcpy(out + (size_t)k * row, px + (size_t)(fb_h - 1 - k) * row, row);
  free(px);
  return out;
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

// A group's cut (groups.h mb_group_inst_moved) of a rounded clip (0, 0)-(100, 100), its corners 26, to (-50, -50)-(150,
// `foot`): the corners at its foot as src/ui/scene.mbt's inst_cut_to has them, round where the cut moves it by a hair
// (MB_CLIP_HAIR) or less, square where by more.
static double group_cut_foot_corner(double foot) {
  double e[MB_GROUP_INST] = {0};
  e[18] = 100.0;
  e[19] = 100.0;
  for (int j = 0; j < 4; j++) e[24 + j] = 26.0;
  mb_group_inst_moved(e, 0, 0.0, 0.0, 0.0, 1, -50.0, -50.0, 150.0, foot);
  return e[26] == e[27] ? e[26] : -1.0;
}

int main(void) {
  // (a group's cut by a hair keeps its corners, as the app's own: scene.mbt clip_hair)
  if (group_cut_foot_corner(99.7) != 26.0 || group_cut_foot_corner(99.5) != 26.0 || group_cut_foot_corner(98.0) != 0.0) {
    LOG("a group's cut by a hair squared a rounded clip's corners, or one by more kept them");
    return 1;
  }
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

  // Perf-35 / Perf-37: lazy shader compilation, compact program groups, scissor glClear partial-redraw ground.
  {
    CHECK(progs[MB_PROG_FROSTED].p == 0 && progs[MB_PROG_LIQUID_MERGED].p == 0 &&
          progs[MB_PROG_LIQUID_SINGLE].p == 0 && progs[MB_PROG_LENS].p == 0 &&
          post == 0 && ad_prog == 0);

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

    CHECK(progs[MB_PROG_FROSTED].p == 0 && progs[MB_PROG_LIQUID_MERGED].p == 0 &&
          progs[MB_PROG_LIQUID_SINGLE].p == 0 && progs[MB_PROG_LENS].p == 0 &&
          post == 0 && ad_prog == 0);
    CHECK(progs[MB_PROG_UI].p != 0);

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
    lq[2 * MB_INST + 7] = 1.0;  // sp = 2.0 -> k == 0
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
    lq[4 * MB_INST + 7] = 1.0;
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
    CHECK((int)bl_p[0] > (int)bg_p[0] + 40 && (int)bl_p[1] > (int)bg_p[1] + 40);
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
    // Native iOS 27 ClearGlassView applies subtle dark-backdrop volumetric lift (~+12/255 at rim=0.6)
    // while staying clearly more transparent than Glass::clear() (cl_veil ~52/255).
    CHECK((int)cl_lens[1] >= (int)cl_bg[1] && (int)cl_lens[1] <= (int)cl_bg[1] + 18 && (int)cl_lens[1] + 10 < (int)cl_veil[1]);
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
    CHECK(top0 > left0 + 20);

    mb_host_glass_light_angle(1.5707963267948966);  // PI / 2
    glass_forget();
    gl_present(la_inst, 2, 0.10, 0.10, 0.12);
    unsigned char *px_la90 = pixels_of_fb(surface);
    int top90 = (int)px_la90[((fb_h - 1 - 21) * fb_w + 100) * 4 + 1];
    int left90 = (int)px_la90[((fb_h - 1 - 70) * fb_w + 51) * 4 + 1];
    int right90 = (int)px_la90[((fb_h - 1 - 70) * fb_w + 149) * 4 + 1];
    CHECK(left90 > top90 + 20);
    CHECK(right90 > top90 + 20);
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
    unsigned char *px_ld[5];
    // (alpha byte, backdrop r, g, b)
    static const double ld_case[5][4] = {
        {0x50, 0, 0, 0}, {0x67, 0, 0, 0}, {0xD9, 0, 0, 0}, {0xD9, 0.0, 0.4, 1.0}, {0xFF, 0.0, 0.4, 1.0}};
    for (int i = 0; i < 5; i++) {
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
    double ld_lum[5];
    for (int i = 0; i < 5; i++) {
      unsigned char *c = px_ld[i] + ((fb_h - 1 - 70) * fb_w + 100) * 4;
      ld_lum[i] = (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255.0;
      printf("gles_render: light glass 0x%02X over (%.1f, %.1f, %.1f): rgb %d %d %d, luma %.4f\n", (int)ld_case[i][0],
             ld_case[i][1], ld_case[i][2], ld_case[i][3], c[0], c[1], c[2], ld_lum[i]);
    }
    CHECK(memcmp(px_ld[0], px_ld[1], (size_t)fb_w * fb_h * 4) == 0);
    CHECK(ld_lum[1] >= 0.49 && ld_lum[1] <= 0.56);
    CHECK(ld_lum[2] >= 0.80 && ld_lum[2] > ld_lum[1] + 0.30);
    CHECK(px_ld[3][((fb_h - 1 - 70) * fb_w + 100) * 4 + 0] >= (int)(0.72 * 255.0 + 0.5));
    unsigned char *c_ff = px_ld[4] + ((fb_h - 1 - 70) * fb_w + 100) * 4;
    CHECK(abs((int)c_ff[0] - 253) <= 4 && abs((int)c_ff[1] - 252) <= 4 && abs((int)c_ff[2] - 253) <= 4);
    for (int i = 0; i < 5; i++) free(px_ld[i]);
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
    CHECK(progs[MB_PROG_FROSTED].p != 0 && progs[MB_PROG_LIQUID_MERGED].p != 0 && progs[MB_PROG_LIQUID_SINGLE].p != 0);
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
  // 2: light glass over a linear ~50% mid-tone (bg=0.72),
  // 3: dark glass (0x20202067) over white (bg=1.0) -> smoked glass surface stays dark-tinted, while light ink
  //    flips dark when composited backdrop luma >= 0.55 so contrast stays >= 3:1 (measured ~8.44:1).
  {
    double ad[4 * MB_INST];
    // 4: light glass over Apple blue #007AFF -> dark ink flips white (sRGB luma 0.414 sat on the dark edge;
    //    the ink decision reads linear-ish luma c*c, 0.236, well inside the dark side)
    // 5: light glass over light gray #F5F5F7 -> stays light glass + dark ink
    struct { double bg, bg_g, bg_b; int dark_glass; double ink; } w7_cases[6] = {
      {1.0, 1.0, 1.0, 0, 0.11},
      {0.0, 0.0, 0.0, 0, 0.11},
      {0.72, 0.72, 0.72, 0, 0.11},
      {1.0, 1.0, 1.0, 1, 0.93},
      {0.0, 122.0 / 255.0, 1.0, 0, 0.11},
      {245.0 / 255.0, 245.0 / 255.0, 247.0 / 255.0, 0, 0.11},
    };
    for (int ci = 0; ci < 6; ci++) {
      double bg = w7_cases[ci].bg, bg_g = w7_cases[ci].bg_g, bg_b = w7_cases[ci].bg_b;
      int dg = w7_cases[ci].dark_glass;
      double ink = w7_cases[ci].ink;
      rect_at(ad, 0, 0, W, H, 0, bg, bg_g, bg_b, 0);
      rect_at(ad + MB_INST, 8, 6, 84, 68, 6,
              dg ? 32.0 / 255.0 : 253.0 / 255.0,
              dg ? 32.0 / 255.0 : 252.0 / 255.0,
              dg ? 32.0 / 255.0 : 253.0 / 255.0, -19);
      ad[MB_INST + 4] = 16;
      ad[MB_INST + 6] = (!dg && ci == 1) ? -1.0 : 1.0;  // ci==1 tests clear-invert opt-in
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
      gl_present(ad, 4, bg, bg_g, bg_b);
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
      } else if (ci == 3) {
        // Dark glass over pure white: same-polarity densified dark glass + light ink (never flips to light gray / black ink)
        CHECK(g_lum >= 0.25 && g_lum <= 0.48);
        CHECK(n_lum > 0.80);
      } else if (ci == 4) {
        CHECK(g_lum > 0.55);
        CHECK(n_lum < 0.25);
      } else {
        CHECK(g_lum > 0.75);
        CHECK(n_lum < 0.25);
      }
      CHECK((int)cp[0] > (int)cp[2] + 120);
      free(px_ad);
    }

    // Wave 7b: adaptive kind 0 translucent hover wash (pad.w < 0, 0x0000001C) inside adaptive=true light glass:
    // 0: white (bg=1.0) -> stays darkened; 1: black (bg=0.0) -> flips luminous white; 2: Apple blue #007AFF -> flips luminous white.
    {
      double ahov[3 * MB_INST];
      struct { double r, g, b; } hov_cases[3] = {
        {1.0, 1.0, 1.0},
        {0.0, 0.0, 0.0},
        {0.0, 122.0 / 255.0, 1.0},
      };
      for (int ci = 0; ci < 3; ci++) {
        double bg = hov_cases[ci].r, bg_g = hov_cases[ci].g, bg_b = hov_cases[ci].b;
        rect_at(ahov, 0, 0, W, H, 0, bg, bg_g, bg_b, 0);
        rect_at(ahov + MB_INST, 8, 6, 84, 68, 6,
                253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -21);
        ahov[MB_INST + 4] = 16;
        ahov[MB_INST + 6] = -1.0;  // clear-invert opt-in
        ahov[MB_INST + 7] = 2.0;
        ahov[MB_INST + 11] = 0x67 / 255.0;
        ahov[MB_INST + 12] = 0.0;
        ahov[MB_INST + 13] = 10.0;
        ahov[MB_INST + 14] = -1.0;
        ahov[MB_INST + 15] = 1.0;
        ahov[MB_INST + 21] = 0.0;
        ahov[MB_INST + 22] = 0.0;
        ahov[MB_INST + 23] = 0.0;
        // Adaptive kind 0 translucent dark hover disc (0x0000001C) on left half of glass
        rect_at(ahov + 2 * MB_INST, 16, 22, 32, 32, 0, 0.0, 0.0, 0.0, 0);
        ahov[2 * MB_INST + 4] = 16.0;
        ahov[2 * MB_INST + 11] = 0x1C / 255.0;
        ahov[2 * MB_INST + 21] = 50.0;
        ahov[2 * MB_INST + 22] = 40.0;
        ahov[2 * MB_INST + 23] = -34.0;
        glass_forget();
        gl_present(ahov, 3, bg, bg_g, bg_b);
        unsigned char *px_h = pixels_of_fb(surface);
        unsigned char *gp = px_h + ((fb_h - 1 - 80) * fb_w + 136) * 4;
        double g_lum = (0.2126 * gp[0] + 0.7152 * gp[1] + 0.0722 * gp[2]) / 255.0;
        unsigned char *hp = px_h + ((fb_h - 1 - 76) * fb_w + 64) * 4;
        double h_lum = (0.2126 * hp[0] + 0.7152 * hp[1] + 0.0722 * hp[2]) / 255.0;
        printf("gles_render: wave7b_hover case=%d glass=%.3f hover=%.3f delta=%+.3f\n",
               ci, g_lum, h_lum, h_lum - g_lum);
        if (ci == 0 || ci == 2) {
          CHECK(h_lum < g_lum - 0.03);
        } else {
          CHECK(h_lum > g_lum + 0.08);
        }
        free(px_h);
      }
    }

    // Clear-invert mode (slot 6 < 0): no thick fog blur (fogT = 0, darkDens = baseDens), stays clear like plain dark glass
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
      fg[2 * MB_INST + 6] = adaptive_on ? -1.0 : 1.0;
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
    printf("gles_render: wave7 clear_invert stripe peak plain_dark=%.3f clear_invert=%.3f\n",
           fog_peaks[0], fog_peaks[1]);
    CHECK(fabs(fog_peaks[1] - fog_peaks[0]) < 0.08);

    // Test A: wide 84x16pt adaptive capsule over deep navy #173255 with centered 16x10pt pure white "{less}" block
    // must resist ping-pong flipping (trimmed mean stays dark -> dark glass + white ink).
    double ta[4 * MB_INST];
    rect_at(ta, 0, 0, W, H, 0, 23.0 / 255.0, 50.0 / 255.0, 85.0 / 255.0, 0);
    rect_at(ta + MB_INST, 42, 31, 16, 10, 0, 1.0, 1.0, 1.0, 0);
    rect_at(ta + 2 * MB_INST, 8, 28, 84, 16, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -21);
    ta[2 * MB_INST + 4] = 8.0;
    ta[2 * MB_INST + 6] = -1.0;  // clear-invert opt-in
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
    CHECK(ta_g < 0.35);
    CHECK(ta_n > 0.80);
    free(px_ta);

    // Test B: cross-frame temporal smoothing + synchronized glass/ink + Schmitt hysteresis + auto-settle stop
    gl_set_fixed_dt(1.0 / 60.0);
    double tb[3 * MB_INST];
    rect_at(tb, 0, 0, W, H, 0, 1.0, 1.0, 1.0, 0);
    rect_at(tb + MB_INST, 8, 28, 84, 16, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -22);
    tb[MB_INST + 4] = 8.0;
    tb[MB_INST + 6] = -1.0;  // clear-invert opt-in
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
    CHECK(prev_g < 0.35);
    CHECK(prev_n > 0.85);

    // Schmitt hysteresis: bg=0.40 (in [0.36, 0.46]) for 25 frames stays dark
    tb[8] = 0.40; tb[9] = 0.40; tb[10] = 0.40;
    for (int s = 0; s < 25; s++) gl_present(tb, 3, 0.40, 0.40, 0.40);
    px_tb = pixels_of_fb(surface);
    double hyst_g = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 2]) / 255.0;
    double hyst_n = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 2]) / 255.0;
    free(px_tb);
    printf("gles_render: wave7 testB hyst_0.40 glass=%.3f ink=%.3f\n", hyst_g, hyst_n);
    CHECK(hyst_g < 0.48);
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

    // Tests C, D, E on a 400x300 @ 1x surface so real-scale capsules (320x44pt large, 240x30pt small)
    // exercise the exact size gate (capHalf >= (140, 19)) and word-level sampling.
    {
      GLuint saved_fb = target_fb;
      int saved_fb_w = fb_w, saved_fb_h = fb_h;
      double saved_cur_w = cur_w, saved_cur_h = cur_h, saved_cur_scale = cur_scale;
      fb_w = 400; fb_h = 300; cur_w = 400; cur_h = 300; cur_scale = 1;
      GLuint big_tex = 0, big_fb = 0;
      glGenTextures(1, &big_tex);
      glBindTexture(GL_TEXTURE_2D, big_tex);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
      glGenFramebuffers(1, &big_fb);
      glBindFramebuffer(GL_FRAMEBUFFER, big_fb);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, big_tex, 0);
      CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
      target_fb = big_fb;

      unsigned char solid_glyph[16 * 16];
      memset(solid_glyph, 255, sizeof(solid_glyph));
      glActiveTexture(GL_TEXTURE0);
      glBindTexture(GL_TEXTURE_2D, atlas);
      glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
      glTexSubImage2D(GL_TEXTURE_2D, 0, 16, 16, 16, 16, GL_RED, GL_UNSIGNED_BYTE, solid_glyph);

      // Test C: wide 320x44pt adaptive light capsule spanning left 45% dark (#141418) + right 55% white (#FFFFFF).
      {
        double tc[9 * MB_INST];
        rect_at(tc, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
        rect_at(tc + MB_INST, 0, 0, 184, 300, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
        rect_at(tc + 2 * MB_INST, 40, 128, 320, 44, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -23);
        tc[2 * MB_INST + 4] = 22.0;
        tc[2 * MB_INST + 6] = -1.0;  // clear-invert opt-in
        tc[2 * MB_INST + 7] = 2.0;
        tc[2 * MB_INST + 11] = 0x67 / 255.0;
        tc[2 * MB_INST + 12] = 0.0;
        tc[2 * MB_INST + 13] = 14.0;
        tc[2 * MB_INST + 14] = -1.0;
        tc[2 * MB_INST + 15] = 1.0;
        tc[2 * MB_INST + 21] = 0.0;
        tc[2 * MB_INST + 22] = 0.0;
        tc[2 * MB_INST + 23] = 0.0;
        // 3: Left subtle ink (kind 10) at center (72, 150)
        rect_at(tc + 3 * MB_INST, 60, 140, 24, 20, 10, 0.34, 0.36, 0.38, 0);
        tc[3 * MB_INST + 4] = 4.0;
        tc[3 * MB_INST + 12] = 0.1; tc[3 * MB_INST + 13] = 0.5;
        tc[3 * MB_INST + 14] = 0.9; tc[3 * MB_INST + 15] = 0.5;
        tc[3 * MB_INST + 21] = 200.0; tc[3 * MB_INST + 22] = 150.0; tc[3 * MB_INST + 23] = 44.0;
        // 4: Left text glyph (kind 7) at center (104, 150)
        rect_at(tc + 4 * MB_INST, 96, 142, 16, 16, 7, 0.14, 0.15, 0.17, 0);
        tc[4 * MB_INST + 12] = 16.0; tc[4 * MB_INST + 13] = 16.0;
        tc[4 * MB_INST + 14] = 16.0; tc[4 * MB_INST + 15] = 16.0;
        tc[4 * MB_INST + 21] = 200.0; tc[4 * MB_INST + 22] = 150.0; tc[4 * MB_INST + 23] = 44.0;
        // 5: Left chromatic accent (kind 10) at center (136, 150)
        rect_at(tc + 5 * MB_INST, 124, 140, 24, 20, 10, 0.90, 0.30, 0.15, 0);
        tc[5 * MB_INST + 4] = 4.0;
        tc[5 * MB_INST + 12] = 0.1; tc[5 * MB_INST + 13] = 0.5;
        tc[5 * MB_INST + 14] = 0.9; tc[5 * MB_INST + 15] = 0.5;
        tc[5 * MB_INST + 21] = 200.0; tc[5 * MB_INST + 22] = 150.0; tc[5 * MB_INST + 23] = 44.0;
        // 6: Right subtle ink (kind 10) at center (232, 150)
        rect_at(tc + 6 * MB_INST, 220, 140, 24, 20, 10, 0.34, 0.36, 0.38, 0);
        tc[6 * MB_INST + 4] = 4.0;
        tc[6 * MB_INST + 12] = 0.1; tc[6 * MB_INST + 13] = 0.5;
        tc[6 * MB_INST + 14] = 0.9; tc[6 * MB_INST + 15] = 0.5;
        tc[6 * MB_INST + 21] = 200.0; tc[6 * MB_INST + 22] = 150.0; tc[6 * MB_INST + 23] = 44.0;
        // 7: Right text glyph (kind 7) at center (268, 150)
        rect_at(tc + 7 * MB_INST, 260, 142, 16, 16, 7, 0.14, 0.15, 0.17, 0);
        tc[7 * MB_INST + 12] = 16.0; tc[7 * MB_INST + 13] = 16.0;
        tc[7 * MB_INST + 14] = 16.0; tc[7 * MB_INST + 15] = 16.0;
        tc[7 * MB_INST + 21] = 200.0; tc[7 * MB_INST + 22] = 150.0; tc[7 * MB_INST + 23] = 44.0;
        // 8: Out-of-bd guard (kind 10) at (16, 16), outside capsule bd capture rect
        rect_at(tc + 8 * MB_INST, 4, 6, 24, 20, 10, 0.34, 0.36, 0.38, 0);
        tc[8 * MB_INST + 4] = 4.0;
        tc[8 * MB_INST + 12] = 0.1; tc[8 * MB_INST + 13] = 0.5;
        tc[8 * MB_INST + 14] = 0.9; tc[8 * MB_INST + 15] = 0.5;
        tc[8 * MB_INST + 21] = 200.0; tc[8 * MB_INST + 22] = 150.0; tc[8 * MB_INST + 23] = 44.0;
        for (int i = 0; i < 9; i++) { tc[i * MB_INST + 18] = 400.0; tc[i * MB_INST + 19] = 300.0; }

        gl_set_fixed_dt(1.0 / 60.0);
        glass_forget();
        gl_present(tc, 9, 1.0, 1.0, 1.0);
        unsigned char *px_tc = pixels_of_fb(big_fb);
        unsigned char *p_ls = px_tc + ((fb_h - 1 - 150) * fb_w + 72) * 4;
        unsigned char *p_lt = px_tc + ((fb_h - 1 - 150) * fb_w + 104) * 4;
        unsigned char *p_lc = px_tc + ((fb_h - 1 - 150) * fb_w + 136) * 4;
        unsigned char *p_rs = px_tc + ((fb_h - 1 - 150) * fb_w + 232) * 4;
        unsigned char *p_rt = px_tc + ((fb_h - 1 - 150) * fb_w + 268) * 4;
        unsigned char *p_rg = px_tc + ((fb_h - 1 - 150) * fb_w + 310) * 4;
        unsigned char *p_ob = px_tc + ((fb_h - 1 - 16) * fb_w + 16) * 4;
        double l_sub = (0.2126 * p_ls[0] + 0.7152 * p_ls[1] + 0.0722 * p_ls[2]) / 255.0;
        double l_txt = (0.2126 * p_lt[0] + 0.7152 * p_lt[1] + 0.0722 * p_lt[2]) / 255.0;
        double r_sub = (0.2126 * p_rs[0] + 0.7152 * p_rs[1] + 0.0722 * p_rs[2]) / 255.0;
        double r_txt = (0.2126 * p_rt[0] + 0.7152 * p_rt[1] + 0.0722 * p_rt[2]) / 255.0;
        double g_right = (0.2126 * p_rg[0] + 0.7152 * p_rg[1] + 0.0722 * p_rg[2]) / 255.0;
        double oob_sub = (0.2126 * p_ob[0] + 0.7152 * p_ob[1] + 0.0722 * p_ob[2]) / 255.0;
        printf("gles_render: wave7 testC half_dark l_sub=%.3f l_txt=%.3f r_sub=%.3f r_txt=%.3f g_right=%.3f oob=%.3f chroma=%d,%d,%d\n",
               l_sub, l_txt, r_sub, r_txt, g_right, oob_sub, p_lc[0], p_lc[1], p_lc[2]);
        CHECK(l_sub < 0.45);
        CHECK(l_txt < 0.25);
        CHECK(r_sub < 0.45);
        CHECK(r_txt < 0.25);
        CHECK(fabs(l_sub - r_sub) < 0.05);
        CHECK(fabs(l_txt - r_txt) < 0.05);
        CHECK(g_right > 0.75);
        CHECK(oob_sub < 0.45);
        CHECK((int)p_lc[0] > (int)p_lc[2] + 120);
        free(px_tc);

        // Expand dark backdrop from 45% to 100% across 20 frames + 10 settle frames:
        double end_l_txt = 0.0, end_r_sub = 0.0, end_g_right = 1.0;
        for (int s = 0; s < 30; s++) {
          double t = s < 20 ? (double)(s + 1) / 20.0 : 1.0;
          tc[MB_INST + 2] = 184.0 + (400.0 - 184.0) * t;
          gl_present(tc, 9, 1.0, 1.0, 1.0);
          px_tc = pixels_of_fb(big_fb);
          p_lt = px_tc + ((fb_h - 1 - 150) * fb_w + 104) * 4;
          p_rs = px_tc + ((fb_h - 1 - 150) * fb_w + 232) * 4;
          p_rg = px_tc + ((fb_h - 1 - 150) * fb_w + 310) * 4;
          end_l_txt = (0.2126 * p_lt[0] + 0.7152 * p_lt[1] + 0.0722 * p_lt[2]) / 255.0;
          end_r_sub = (0.2126 * p_rs[0] + 0.7152 * p_rs[1] + 0.0722 * p_rs[2]) / 255.0;
          end_g_right = (0.2126 * p_rg[0] + 0.7152 * p_rg[1] + 0.0722 * p_rg[2]) / 255.0;
          free(px_tc);
        }
        printf("gles_render: wave7 testC scroll_to_full end_l_txt=%.3f end_r_sub=%.3f end_g_right=%.3f\n",
               end_l_txt, end_r_sub, end_g_right);
        CHECK(end_l_txt > 0.75);
        CHECK(end_r_sub > 0.68);
        CHECK(end_g_right < 0.35);

        // Test C-frost: light adaptive glass accounts for user glassFrost / Increase Contrast opacity (tint_a).
        {
          tc[MB_INST + 2] = 184.0;
          tc[2 * MB_INST + 11] = 0x67 / 255.0;
          glass_forget();
          gl_present(tc, 9, 1.0, 1.0, 1.0);
          px_tc = pixels_of_fb(big_fb);
          p_lt = px_tc + ((fb_h - 1 - 150) * fb_w + 104) * 4;
          CHECK((0.2126 * p_lt[0] + 0.7152 * p_lt[1] + 0.0722 * p_lt[2]) / 255.0 < 0.25);
          free(px_tc);

          const double frost_alphas[3] = {0.522, 0.752, 0.913};
          for (int fi = 0; fi < 3; fi++) {
            tc[2 * MB_INST + 11] = frost_alphas[fi];
            gl_present(tc, 9, 1.0, 1.0, 1.0);
            px_tc = pixels_of_fb(big_fb);
            p_ls = px_tc + ((fb_h - 1 - 150) * fb_w + 72) * 4;
            p_lt = px_tc + ((fb_h - 1 - 150) * fb_w + 104) * 4;
            unsigned char *p_lg = px_tc + ((fb_h - 1 - 150) * fb_w + 155) * 4;
            double fl_sub = (0.2126 * p_ls[0] + 0.7152 * p_ls[1] + 0.0722 * p_ls[2]) / 255.0;
            double fl_txt = (0.2126 * p_lt[0] + 0.7152 * p_lt[1] + 0.0722 * p_lt[2]) / 255.0;
            double fl_gl = (0.2126 * p_lg[0] + 0.7152 * p_lg[1] + 0.0722 * p_lg[2]) / 255.0;
            printf("gles_render: wave7 testC_frost half_dark a=%.3f l_sub=%.3f l_txt=%.3f l_glass=%.3f\n",
                   frost_alphas[fi], fl_sub, fl_txt, fl_gl);
            CHECK(fl_sub < 0.45);
            CHECK(fl_txt < 0.25);
            CHECK(fl_gl > 0.56);
            free(px_tc);
          }

          tc[2 * MB_INST + 11] = 0x67 / 255.0;
          gl_present(tc, 9, 1.0, 1.0, 1.0);
          px_tc = pixels_of_fb(big_fb);
          p_lt = px_tc + ((fb_h - 1 - 150) * fb_w + 104) * 4;
          CHECK((0.2126 * p_lt[0] + 0.7152 * p_lt[1] + 0.0722 * p_lt[2]) / 255.0 < 0.25);
          free(px_tc);

          tc[MB_INST + 2] = 400.0;
          tc[2 * MB_INST + 11] = 0x67 / 255.0;
          glass_forget();
          gl_present(tc, 9, 1.0, 1.0, 1.0);
          px_tc = pixels_of_fb(big_fb);
          p_lt = px_tc + ((fb_h - 1 - 150) * fb_w + 104) * 4;
          p_rg = px_tc + ((fb_h - 1 - 150) * fb_w + 310) * 4;
          CHECK((0.2126 * p_lt[0] + 0.7152 * p_lt[1] + 0.0722 * p_lt[2]) / 255.0 > 0.75);
          CHECK((0.2126 * p_rg[0] + 0.7152 * p_rg[1] + 0.0722 * p_rg[2]) / 255.0 < 0.35);
          free(px_tc);

          tc[2 * MB_INST + 11] = 0.913;
          gl_present(tc, 9, 1.0, 1.0, 1.0);
          px_tc = pixels_of_fb(big_fb);
          p_lt = px_tc + ((fb_h - 1 - 150) * fb_w + 104) * 4;
          p_rg = px_tc + ((fb_h - 1 - 150) * fb_w + 310) * 4;
          double fd_txt = (0.2126 * p_lt[0] + 0.7152 * p_lt[1] + 0.0722 * p_lt[2]) / 255.0;
          double fd_gl = (0.2126 * p_rg[0] + 0.7152 * p_rg[1] + 0.0722 * p_rg[2]) / 255.0;
          printf("gles_render: wave7 testC_frost full_dark a=0.913 txt=%.3f glass=%.3f settling=%d\n",
                 fd_txt, fd_gl, gl_adaptive_settling());
          CHECK(fd_txt < 0.25);
          CHECK(fd_gl > 0.85);
          CHECK(gl_adaptive_settling() == 0);
          free(px_tc);

          tc[2 * MB_INST + 11] = 0.752;
          glass_forget();
          gl_present(tc, 9, 1.0, 1.0, 1.0);
          px_tc = pixels_of_fb(big_fb);
          p_lt = px_tc + ((fb_h - 1 - 150) * fb_w + 104) * 4;
          p_rg = px_tc + ((fb_h - 1 - 150) * fb_w + 310) * 4;
          double f65_txt = (0.2126 * p_lt[0] + 0.7152 * p_lt[1] + 0.0722 * p_lt[2]) / 255.0;
          double f65_gl = (0.2126 * p_rg[0] + 0.7152 * p_rg[1] + 0.0722 * p_rg[2]) / 255.0;
          printf("gles_render: wave7 testC_frost full_dark a=0.752 txt=%.3f glass=%.3f\n", f65_txt, f65_gl);
          CHECK(f65_txt < 0.25);
          CHECK(f65_gl > 0.72);
          free(px_tc);
        }
      }

      // Test D: small 240x30pt adaptive capsule straddling white/dark horizontal edge:
      // disables local override so uppercase 'H' and lowercase 'o' stay dark (< 0.35) and match.
      {
        double td[5 * MB_INST];
        rect_at(td, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
        rect_at(td + MB_INST, 0, 152, 400, 148, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
        rect_at(td + 2 * MB_INST, 80, 135, 240, 30, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -24);
        td[2 * MB_INST + 4] = 15.0;
        td[2 * MB_INST + 6] = 1.0;
        td[2 * MB_INST + 7] = 2.0;
        td[2 * MB_INST + 11] = 0x67 / 255.0;
        td[2 * MB_INST + 12] = 0.0;
        td[2 * MB_INST + 13] = 12.0;
        td[2 * MB_INST + 14] = -1.0;
        td[2 * MB_INST + 15] = 1.0;
        rect_at(td + 3 * MB_INST, 180, 138, 12, 12, 7, 0.14, 0.15, 0.17, 0);
        td[3 * MB_INST + 12] = 16.0; td[3 * MB_INST + 13] = 16.0;
        td[3 * MB_INST + 14] = 16.0; td[3 * MB_INST + 15] = 16.0;
        td[3 * MB_INST + 21] = 200.0; td[3 * MB_INST + 22] = 150.0; td[3 * MB_INST + 23] = 30.0;
        rect_at(td + 4 * MB_INST, 196, 153, 12, 10, 7, 0.14, 0.15, 0.17, 0);
        td[4 * MB_INST + 12] = 16.0; td[4 * MB_INST + 13] = 16.0;
        td[4 * MB_INST + 14] = 16.0; td[4 * MB_INST + 15] = 16.0;
        td[4 * MB_INST + 21] = 200.0; td[4 * MB_INST + 22] = 150.0; td[4 * MB_INST + 23] = 30.0;
        for (int i = 0; i < 5; i++) { td[i * MB_INST + 18] = 400.0; td[i * MB_INST + 19] = 300.0; }
        glass_forget();
        gl_present(td, 5, 1.0, 1.0, 1.0);
        unsigned char *px_td = pixels_of_fb(big_fb);
        unsigned char *p_H = px_td + ((fb_h - 1 - 144) * fb_w + 186) * 4;
        unsigned char *p_o = px_td + ((fb_h - 1 - 158) * fb_w + 202) * 4;
        double l_H = (0.2126 * p_H[0] + 0.7152 * p_H[1] + 0.0722 * p_H[2]) / 255.0;
        double l_o = (0.2126 * p_o[0] + 0.7152 * p_o[1] + 0.0722 * p_o[2]) / 255.0;
        printf("gles_render: wave7 testD small_pill_no_local l_H=%.3f l_o=%.3f\n", l_H, l_o);
        CHECK(l_H < 0.35);
        CHECK(l_o < 0.35);
        CHECK(fabs(l_H - l_o) < 0.05);
        free(px_td);
      }

      // Test E1: expanded 320x80pt large capsule (capHalf.y=40 > 28) with dark quadrant 0..184 x 0..152.
      // Center-relative offsets in slots 6-7: tall 'H' (y=138..148) and short 'o' (y=154..164) share line_cy=142,
      // and trailing 'i' (x=180..192 straddling x=184) shifts slot 6 to word center x=160: all 3 invert bright (> 0.82).
      {
        double te1[6 * MB_INST];
        rect_at(te1, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
        rect_at(te1 + MB_INST, 0, 0, 184, 152, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
        rect_at(te1 + 2 * MB_INST, 40, 110, 320, 80, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -25);
        te1[2 * MB_INST + 4] = 22.0;
        te1[2 * MB_INST + 6] = 1.0;
        te1[2 * MB_INST + 7] = 2.0;
        te1[2 * MB_INST + 11] = 0x67 / 255.0;
        te1[2 * MB_INST + 12] = 0.0;
        te1[2 * MB_INST + 13] = 14.0;
        te1[2 * MB_INST + 14] = -1.0;
        te1[2 * MB_INST + 15] = 1.0;
        rect_at(te1 + 3 * MB_INST, 96, 138, 12, 10, 7, 0.14, 0.15, 0.17, 0);
        te1[3 * MB_INST + 6] = 0.0; te1[3 * MB_INST + 7] = 142.0 - 143.0;
        te1[3 * MB_INST + 12] = 16.0; te1[3 * MB_INST + 13] = 16.0;
        te1[3 * MB_INST + 14] = 16.0; te1[3 * MB_INST + 15] = 16.0;
        te1[3 * MB_INST + 21] = 200.0; te1[3 * MB_INST + 22] = 150.0; te1[3 * MB_INST + 23] = 80.0;
        rect_at(te1 + 4 * MB_INST, 112, 154, 12, 10, 7, 0.14, 0.15, 0.17, 0);
        te1[4 * MB_INST + 6] = 0.0; te1[4 * MB_INST + 7] = 142.0 - 159.0;
        te1[4 * MB_INST + 12] = 16.0; te1[4 * MB_INST + 13] = 16.0;
        te1[4 * MB_INST + 14] = 16.0; te1[4 * MB_INST + 15] = 16.0;
        te1[4 * MB_INST + 21] = 200.0; te1[4 * MB_INST + 22] = 150.0; te1[4 * MB_INST + 23] = 80.0;
        rect_at(te1 + 5 * MB_INST, 180, 138, 12, 10, 7, 0.14, 0.15, 0.17, 0);
        te1[5 * MB_INST + 6] = 160.0 - 186.0; te1[5 * MB_INST + 7] = 142.0 - 143.0;
        te1[5 * MB_INST + 12] = 16.0; te1[5 * MB_INST + 13] = 16.0;
        te1[5 * MB_INST + 14] = 16.0; te1[5 * MB_INST + 15] = 16.0;
        te1[5 * MB_INST + 21] = 200.0; te1[5 * MB_INST + 22] = 150.0; te1[5 * MB_INST + 23] = 80.0;
        for (int i = 0; i < 6; i++) { te1[i * MB_INST + 18] = 400.0; te1[i * MB_INST + 19] = 300.0; }
        glass_forget();
        gl_present(te1, 6, 1.0, 1.0, 1.0);
        unsigned char *px_e1 = pixels_of_fb(big_fb);
        unsigned char *p_H = px_e1 + ((fb_h - 1 - 143) * fb_w + 102) * 4;
        unsigned char *p_o = px_e1 + ((fb_h - 1 - 159) * fb_w + 118) * 4;
        unsigned char *p_i = px_e1 + ((fb_h - 1 - 143) * fb_w + 186) * 4;
        double l_H = (0.2126 * p_H[0] + 0.7152 * p_H[1] + 0.0722 * p_H[2]) / 255.0;
        double l_o = (0.2126 * p_o[0] + 0.7152 * p_o[1] + 0.0722 * p_o[2]) / 255.0;
        double l_i = (0.2126 * p_i[0] + 0.7152 * p_i[1] + 0.0722 * p_i[2]) / 255.0;
        printf("gles_render: wave7 testE1 line_word_unified l_H=%.3f l_o=%.3f l_i=%.3f\n", l_H, l_o, l_i);
        CHECK(l_H < 0.25 && l_o < 0.25 && l_i < 0.25 && fabs(l_H - l_o) < 0.05 && fabs(l_H - l_i) < 0.05);
        free(px_e1);
      }

      // Test E2: macro spatial low-pass rejects short-range oscillation.
      // 320x44pt large capsule over left dark region (0..184) with an embedded 16x10pt 2D white highlight (100..116, 145..155).
      // Three adjacent glyphs at x=90, x=108 (over highlight), x=126 must all stay bright (> 0.82, diff < 0.05),
      // while the right-side glyph at x=268 over white stays dark (< 0.35).
      {
        double te2[8 * MB_INST];
        rect_at(te2, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
        rect_at(te2 + MB_INST, 0, 0, 184, 300, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
        rect_at(te2 + 2 * MB_INST, 100, 145, 16, 10, 0, 1.0, 1.0, 1.0, 0);
        rect_at(te2 + 3 * MB_INST, 40, 128, 320, 44, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -27);
        te2[3 * MB_INST + 4] = 22.0;
        te2[3 * MB_INST + 6] = 1.0;
        te2[3 * MB_INST + 7] = 2.0;
        te2[3 * MB_INST + 11] = 0x67 / 255.0;
        te2[3 * MB_INST + 12] = 0.0;
        te2[3 * MB_INST + 13] = 14.0;
        te2[3 * MB_INST + 14] = -1.0;
        te2[3 * MB_INST + 15] = 1.0;
        double gx_xs[4] = { 84.0, 102.0, 120.0, 262.0 };
        for (int k = 0; k < 4; k++) {
          double *g = te2 + (4 + k) * MB_INST;
          rect_at(g, gx_xs[k], 142, 12, 16, 7, 0.14, 0.15, 0.17, 0);
          g[6] = 0.0; g[7] = 0.0;
          g[12] = 16.0; g[13] = 16.0; g[14] = 16.0; g[15] = 16.0;
          g[21] = 200.0; g[22] = 150.0; g[23] = 44.0;
        }
        for (int i = 0; i < 8; i++) { te2[i * MB_INST + 18] = 400.0; te2[i * MB_INST + 19] = 300.0; }
        glass_forget();
        gl_present(te2, 8, 1.0, 1.0, 1.0);
        unsigned char *px_e2 = pixels_of_fb(big_fb);
        unsigned char *p1 = px_e2 + ((fb_h - 1 - 150) * fb_w + 90) * 4;
        unsigned char *p2 = px_e2 + ((fb_h - 1 - 150) * fb_w + 108) * 4;
        unsigned char *p3 = px_e2 + ((fb_h - 1 - 150) * fb_w + 126) * 4;
        unsigned char *p4 = px_e2 + ((fb_h - 1 - 150) * fb_w + 268) * 4;
        double l1 = (0.2126 * p1[0] + 0.7152 * p1[1] + 0.0722 * p1[2]) / 255.0;
        double l2 = (0.2126 * p2[0] + 0.7152 * p2[1] + 0.0722 * p2[2]) / 255.0;
        double l3 = (0.2126 * p3[0] + 0.7152 * p3[1] + 0.0722 * p3[2]) / 255.0;
        double l4 = (0.2126 * p4[0] + 0.7152 * p4[1] + 0.0722 * p4[2]) / 255.0;
        printf("gles_render: wave7 testE2 lowpass_anti_osc l1=%.3f l2=%.3f l3=%.3f l4=%.3f\n",
               l1, l2, l3, l4);
        CHECK(l1 < 0.25 && l2 < 0.25 && l3 < 0.25 && l4 < 0.25);
        CHECK(fabs(l1 - l2) < 0.05 && fabs(l2 - l3) < 0.05 && fabs(l3 - l4) < 0.05);
        free(px_e2);
      }

      // Test F: expanded 320x80pt large capsule (capHalf.y=40 > 28) with horizontal dark/white boundary at y=152
      // (top-left dark quadrant so whole capsule stays light). Two kind-11 vector bands share p.zw -> (104, 142):
      // both bands must invert bright (> 0.82) with matching luma (no band-splitting).
      {
        double tf[6 * MB_INST];
        rect_at(tf, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
        rect_at(tf + MB_INST, 0, 0, 184, 152, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
        rect_at(tf + 2 * MB_INST, 40, 110, 320, 80, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -26);
        tf[2 * MB_INST + 4] = 22.0;
        tf[2 * MB_INST + 6] = 1.0;
        tf[2 * MB_INST + 7] = 2.0;
        tf[2 * MB_INST + 11] = 0x67 / 255.0;
        tf[2 * MB_INST + 12] = 0.0;
        tf[2 * MB_INST + 13] = 14.0;
        tf[2 * MB_INST + 14] = -1.0;
        tf[2 * MB_INST + 15] = 1.0;
        rect_at(tf + 3 * MB_INST, 96, 138, 16, 10, 11, 0.14, 0.15, 0.17, 0);
        tf[3 * MB_INST + 4] = 4.0;
        tf[3 * MB_INST + 6] = 104.0 - 104.0; tf[3 * MB_INST + 7] = 142.0 - 143.0;
        tf[3 * MB_INST + 12] = 0.0; tf[3 * MB_INST + 13] = 1.0;
        tf[3 * MB_INST + 21] = 200.0; tf[3 * MB_INST + 22] = 150.0; tf[3 * MB_INST + 23] = 80.0;
        rect_at(tf + 4 * MB_INST, 96, 154, 16, 10, 11, 0.14, 0.15, 0.17, 0);
        tf[4 * MB_INST + 4] = 4.0;
        tf[4 * MB_INST + 6] = 104.0 - 104.0; tf[4 * MB_INST + 7] = 142.0 - 159.0;
        tf[4 * MB_INST + 12] = 0.0; tf[4 * MB_INST + 13] = 1.0;
        tf[4 * MB_INST + 21] = 200.0; tf[4 * MB_INST + 22] = 150.0; tf[4 * MB_INST + 23] = 80.0;
        for (int i = 0; i < 5; i++) { tf[i * MB_INST + 18] = 400.0; tf[i * MB_INST + 19] = 300.0; }
        memset(tf + 5 * MB_INST, 0, MB_INST * sizeof(double));
        tf[5 * MB_INST + 0] = 0.1; tf[5 * MB_INST + 1] = 0.5;
        tf[5 * MB_INST + 2] = 0.9; tf[5 * MB_INST + 3] = 0.5;
        tf[5 * MB_INST + 5] = 12.0;

        glass_forget();
        gl_present(tf, 6, 1.0, 1.0, 1.0);
        unsigned char *px_tf = pixels_of_fb(big_fb);
        unsigned char *p_top = px_tf + ((fb_h - 1 - 143) * fb_w + 104) * 4;
        unsigned char *p_bot = px_tf + ((fb_h - 1 - 159) * fb_w + 104) * 4;
        double l_top = (0.2126 * p_top[0] + 0.7152 * p_top[1] + 0.0722 * p_top[2]) / 255.0;
        double l_bot = (0.2126 * p_bot[0] + 0.7152 * p_bot[1] + 0.0722 * p_bot[2]) / 255.0;
        printf("gles_render: wave7 testF icon_bands_unified l_top=%.3f l_bot=%.3f\n", l_top, l_bot);
        CHECK(l_top < 0.25 && l_bot < 0.25 && fabs(l_top - l_bot) < 0.05);
        free(px_tf);
      }

      gl_set_fixed_dt(0.0);
      glass_forget();
      target_fb = saved_fb;
      fb_w = saved_fb_w; fb_h = saved_fb_h;
      cur_w = saved_cur_w; cur_h = saved_cur_h; cur_scale = saved_cur_scale;
      glBindFramebuffer(GL_FRAMEBUFFER, target_fb);
      glDeleteFramebuffers(1, &big_fb);
      glDeleteTextures(1, &big_tex);
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
    CHECK(mb_glass_damage_expand(f, 7, r, &rn, W, H, S, NULL));
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
    CHECK(mb_glass_damage_expand(f, 4, r, &rn, 200, 100, 1, NULL));
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
    // Progressive blur zero-tint regression: dark background (0.15, 0.15, 0.16) under kind==5 progressive blur
    // with blur=8.5, saturation=1.0, tint=(1.0, 1.0, 1.0, 0.0) must stay pure dark (~38, 38, 41) at r=1.0
    // without any contrast-boosted white veil.
    {
      double zt[2 * MB_INST];
      rect_at(zt, 0, 0, W, H, 0, 0.15, 0.15, 0.16, 0);
      rect_at(zt + MB_INST, 0, 0, W, 68.0, 5, 1.0, 1.0, 1.0, -42);
      zt[MB_INST + 6] = 1.0;   // saturation=1.0
      zt[MB_INST + 7] = 8.5;   // blur=8.5
      zt[MB_INST + 11] = 0.0;  // tint alpha=0.0 (clear)
      zt[MB_INST + 15] = 1.0;
      zt[MB_INST + 22] = -1.0; // progressive
      zt[MB_INST + 54] = 68.0;
      zt[MB_INST + 55] = 40.0; // y in [0, 28] has fade_r == 1.0
      glass_forget();
      gl_present(zt, 2, 0.15, 0.15, 0.16);
      unsigned char *zpx = pixels_of_fb(pb_fb);
      int py = 10 * (int)cur_scale;
      int row = fb_h - 1 - py;
      int px_x = 50 * (int)cur_scale;
      int zidx = (row * fb_w + px_x) * 4;
      int zr = zpx[zidx + 0], zg = zpx[zidx + 1], zb = zpx[zidx + 2];
      printf("gles_render: prog-blur zero-tint rgb=(%d,%d,%d)\n", zr, zg, zb);
      CHECK(abs(zr - 38) <= 2 && abs(zg - 38) <= 2 && abs(zb - 41) <= 2);
      free(zpx);
    }
    // Bare-text kind==7 (negative pad.w) bidirectional adaptive ink over kind==5 zero-tint progressive blur
    // with non-uniform left/right backdrop (left kind==6 pill over opposite luminance from right bare text):
    // (a) left bright / right dark + bare dark text -> flips light (>= 0.70 luma)
    // (b) left dark / right bright + bare light text -> flips dark (<= 0.30 luma)
    // Plus WCAG >= 4.5:1 contrast on mid-gray sRGB 0.45, 0.60, 0.77 for both dark and light origin bare text,
    // and capsule white text (pad.w > 0) over ad_n == 0 bright backdrop staying white (>= 0.90 luma).
    {
      struct { double l_bg, r_bg, txt; int expect_light; } bi_cases[2] = {
        { 0.96, 0.12, 0.11, 1 },
        { 0.12, 0.96, 0.95, 0 },
      };
      for (int ci = 0; ci < 2; ci++) {
        double bi[5 * MB_INST];
        rect_at(bi, 0, 0, 40, H, 0, bi_cases[ci].l_bg, bi_cases[ci].l_bg, bi_cases[ci].l_bg, 0);
        rect_at(bi + MB_INST, 40, 0, W - 40, H, 0, bi_cases[ci].r_bg, bi_cases[ci].r_bg, bi_cases[ci].r_bg, 0);
        rect_at(bi + 2 * MB_INST, 0, 0, W, 68.0, 5, 1.0, 1.0, 1.0, -43);
        bi[2 * MB_INST + 6] = 1.0; bi[2 * MB_INST + 7] = 8.5; bi[2 * MB_INST + 11] = 0.0; bi[2 * MB_INST + 15] = 1.0;
        bi[2 * MB_INST + 22] = -1.0; bi[2 * MB_INST + 54] = 68.0; bi[2 * MB_INST + 55] = 40.0;
        rect_at(bi + 3 * MB_INST, 4, 8, 24, 20, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -44);
        bi[3 * MB_INST + 4] = 10.0; bi[3 * MB_INST + 6] = 1.0; bi[3 * MB_INST + 7] = 2.0;
        bi[3 * MB_INST + 11] = 0x67 / 255.0; bi[3 * MB_INST + 14] = -1.0; bi[3 * MB_INST + 15] = 1.0;
        rect_at(bi + 4 * MB_INST, 64, 12, 12, 12, 7, bi_cases[ci].txt, bi_cases[ci].txt, bi_cases[ci].txt, 0);
        bi[4 * MB_INST + 12] = 16.0; bi[4 * MB_INST + 13] = 16.0;
        bi[4 * MB_INST + 14] = 16.0; bi[4 * MB_INST + 15] = 16.0;
        bi[4 * MB_INST + 21] = 70.0; bi[4 * MB_INST + 22] = 18.0; bi[4 * MB_INST + 23] = bare_ink(12, 12);
        glass_forget();
        gl_present(bi, 5, bi_cases[ci].r_bg, bi_cases[ci].r_bg, bi_cases[ci].r_bg);
        unsigned char *bpx = pixels_of_fb(pb_fb);
        int py = 18 * (int)cur_scale;
        int row = fb_h - 1 - py;
        int px_x = 70 * (int)cur_scale;
        int bidx = (row * fb_w + px_x) * 4;
        double lum = (0.2126 * bpx[bidx + 0] + 0.7152 * bpx[bidx + 1] + 0.0722 * bpx[bidx + 2]) / 255.0;
        printf("gles_render: bare-text adaptive ink non-uniform case %d: rgb=(%d,%d,%d) luma=%.3f\n",
               ci, bpx[bidx + 0], bpx[bidx + 1], bpx[bidx + 2], lum);
        if (bi_cases[ci].expect_light) {
          CHECK(lum >= 0.70);
        } else {
          CHECK(lum <= 0.30);
        }
        free(bpx);
      }
      // Mid-gray WCAG >= 4.5:1 contrast check on 8 mid-grays x 5 primary/muted inks (40 cases)
      double mid_bgs[8] = { 0.45, 0.47, 0.50, 0.53, 0.60, 0.63, 0.70, 0.77 };
      double mid_txts[5] = { 0.11, 0.40, 0.67, 0.95, 1.00 };
      for (int mi = 0; mi < 8; mi++) {
        double bg = mid_bgs[mi];
        double bg_lin = bg <= 0.04045 ? bg / 12.92 : pow((bg + 0.055) / 1.055, 2.4);
        for (int ti = 0; ti < 5; ti++) {
          double mc[3 * MB_INST];
          rect_at(mc, 0, 0, W, H, 0, bg, bg, bg, 0);
          rect_at(mc + MB_INST, 0, 0, W, 68.0, 5, 1.0, 1.0, 1.0, -45);
          mc[MB_INST + 6] = 1.0; mc[MB_INST + 7] = 8.5; mc[MB_INST + 11] = 0.0; mc[MB_INST + 15] = 1.0;
          mc[MB_INST + 22] = -1.0; mc[MB_INST + 54] = 68.0; mc[MB_INST + 55] = 40.0;
          rect_at(mc + 2 * MB_INST, 44, 12, 12, 12, 7, mid_txts[ti], mid_txts[ti], mid_txts[ti], 0);
          mc[2 * MB_INST + 12] = 16.0; mc[2 * MB_INST + 13] = 16.0;
          mc[2 * MB_INST + 14] = 16.0; mc[2 * MB_INST + 15] = 16.0;
          mc[2 * MB_INST + 21] = 50.0; mc[2 * MB_INST + 22] = 18.0; mc[2 * MB_INST + 23] = bare_ink(12, 12);
          glass_forget();
          gl_present(mc, 3, bg, bg, bg);
          unsigned char *mpx = pixels_of_fb(pb_fb);
          int py = 18 * (int)cur_scale;
          int row = fb_h - 1 - py;
          int px_x = 50 * (int)cur_scale;
          int midx = (row * fb_w + px_x) * 4;
          double tr = mpx[midx + 0] / 255.0, tg = mpx[midx + 1] / 255.0, tb = mpx[midx + 2] / 255.0;
          double rl = 0.2126 * (tr <= 0.04045 ? tr / 12.92 : pow((tr + 0.055) / 1.055, 2.4))
                    + 0.7152 * (tg <= 0.04045 ? tg / 12.92 : pow((tg + 0.055) / 1.055, 2.4))
                    + 0.0722 * (tb <= 0.04045 ? tb / 12.92 : pow((tb + 0.055) / 1.055, 2.4));
          double hi = rl > bg_lin ? rl : bg_lin, lo = rl > bg_lin ? bg_lin : rl;
          double cr = (hi + 0.05) / (lo + 0.05);
          printf("gles_render: bare-text mid-gray bg=%.2f txt=%.2f -> rgb=(%d,%d,%d) cr=%.2f\n",
                 bg, mid_txts[ti], mpx[midx + 0], mpx[midx + 1], mpx[midx + 2], cr);
          CHECK(cr >= 4.5);
          free(mpx);
        }
      }
      // Capsule white text (pad.w > 0) over ad_n == 0 bright backdrop must NOT flip dark
      {
        double cw[3 * MB_INST];
        rect_at(cw, 0, 0, W, H, 0, 0.96, 0.96, 0.96, 0);
        rect_at(cw + MB_INST, 0, 0, W, 68.0, 5, 1.0, 1.0, 1.0, -46);
        cw[MB_INST + 6] = 1.0; cw[MB_INST + 7] = 8.5; cw[MB_INST + 11] = 0.0; cw[MB_INST + 15] = 1.0;
        cw[MB_INST + 22] = -1.0; cw[MB_INST + 54] = 68.0; cw[MB_INST + 55] = 40.0;
        rect_at(cw + 2 * MB_INST, 44, 12, 12, 12, 7, 0.95, 0.95, 0.95, 0);
        cw[2 * MB_INST + 12] = 16.0; cw[2 * MB_INST + 13] = 16.0;
        cw[2 * MB_INST + 14] = 16.0; cw[2 * MB_INST + 15] = 16.0;
        cw[2 * MB_INST + 21] = 50.0; cw[2 * MB_INST + 22] = 18.0; cw[2 * MB_INST + 23] = 12.0; // positive = capsule
        glass_forget();
        gl_present(cw, 3, 0.96, 0.96, 0.96);
        unsigned char *cpx = pixels_of_fb(pb_fb);
        int py = 18 * (int)cur_scale;
        int row = fb_h - 1 - py;
        int px_x = 50 * (int)cur_scale;
        int cidx = (row * fb_w + px_x) * 4;
        double lum = (0.2126 * cpx[cidx + 0] + 0.7152 * cpx[cidx + 1] + 0.0722 * cpx[cidx + 2]) / 255.0;
        printf("gles_render: capsule white text ad_n=0 bright bg: rgb=(%d,%d,%d) luma=%.3f\n",
               cpx[cidx + 0], cpx[cidx + 1], cpx[cidx + 2], lum);
        CHECK(lum >= 0.90);
        free(cpx);
      }
      // Bare kind==10 (line) & kind==11 (shape bands with p.zw unified center) + kind==7 on #F00080 exact WCAG luma
      {
        struct { double r, g, b; const char *name; } bg_cases[4] = {
          { 0.96, 0.96, 0.96, "light" },
          { 0.12, 0.12, 0.12, "dark" },
          { 0.50, 0.50, 0.50, "mid50" },
          { 240.0 / 255.0, 0.0, 128.0 / 255.0, "#F00080" },
        };
        double inks[2] = { 0.11, 0.95 };
        for (int bi_i = 0; bi_i < 4; bi_i++) {
          double br = bg_cases[bi_i].r, bgc = bg_cases[bi_i].g, bb = bg_cases[bi_i].b;
          double bg_lin = 0.2126 * (br <= 0.04045 ? br / 12.92 : pow((br + 0.055) / 1.055, 2.4))
                        + 0.7152 * (bgc <= 0.04045 ? bgc / 12.92 : pow((bgc + 0.055) / 1.055, 2.4))
                        + 0.0722 * (bb <= 0.04045 ? bb / 12.92 : pow((bb + 0.055) / 1.055, 2.4));
          for (int ii = 0; ii < 2; ii++) {
            double ink = inks[ii];
            double sc[6 * MB_INST];
            rect_at(sc, 0, 0, W, H, 0, br, bgc, bb, 0);
            rect_at(sc + MB_INST, 0, 0, W, 68.0, 5, 1.0, 1.0, 1.0, -47);
            sc[MB_INST + 6] = 1.0; sc[MB_INST + 7] = 8.5; sc[MB_INST + 11] = 0.0; sc[MB_INST + 15] = 1.0;
            sc[MB_INST + 22] = -1.0; sc[MB_INST + 54] = 68.0; sc[MB_INST + 55] = 40.0;
            // kind 7 bare glyph at (20, 18)
            rect_at(sc + 2 * MB_INST, 14, 12, 12, 12, 7, ink, ink, ink, 0);
            sc[2 * MB_INST + 12] = 16.0; sc[2 * MB_INST + 13] = 16.0;
            sc[2 * MB_INST + 14] = 16.0; sc[2 * MB_INST + 15] = 16.0;
            sc[2 * MB_INST + 21] = 20.0; sc[2 * MB_INST + 22] = 18.0; sc[2 * MB_INST + 23] = bare_ink(12, 12);
            // kind 10 bare line at (50, 18)
            rect_at(sc + 3 * MB_INST, 42, 12, 16, 12, 10, ink, ink, ink, 0);
            sc[3 * MB_INST + 4] = 4.0;
            sc[3 * MB_INST + 12] = 0.1; sc[3 * MB_INST + 13] = 0.5;
            sc[3 * MB_INST + 14] = 0.9; sc[3 * MB_INST + 15] = 0.5;
            sc[3 * MB_INST + 21] = 50.0; sc[3 * MB_INST + 22] = 18.0; sc[3 * MB_INST + 23] = -12.0;
            // kind 11 bare shape at (80, 18)
            rect_at(sc + 4 * MB_INST, 72, 12, 16, 12, 11, ink, ink, ink, 0);
            sc[4 * MB_INST + 4] = 4.0;
            sc[4 * MB_INST + 6] = 0.0; sc[4 * MB_INST + 7] = 0.0;
            sc[4 * MB_INST + 12] = 0.0; sc[4 * MB_INST + 13] = 1.0;
            sc[4 * MB_INST + 21] = 80.0; sc[4 * MB_INST + 22] = 18.0; sc[4 * MB_INST + 23] = -12.0;
            memset(sc + 5 * MB_INST, 0, MB_INST * sizeof(double));
            sc[5 * MB_INST + 0] = 0.1; sc[5 * MB_INST + 1] = 0.5;
            sc[5 * MB_INST + 2] = 0.9; sc[5 * MB_INST + 3] = 0.5;
            sc[5 * MB_INST + 5] = 12.0;
            glass_forget();
            gl_present(sc, 6, br, bgc, bb);
            unsigned char *spx = pixels_of_fb(pb_fb);
            int xs[3] = { 20, 50, 80 };
            int kinds[3] = { 7, 10, 11 };
            for (int ki = 0; ki < 3; ki++) {
              int py = 18 * (int)cur_scale;
              int row = fb_h - 1 - py;
              int px_x = xs[ki] * (int)cur_scale;
              int idx = (row * fb_w + px_x) * 4;
              double tr = spx[idx + 0] / 255.0, tg = spx[idx + 1] / 255.0, tb = spx[idx + 2] / 255.0;
              double rl = 0.2126 * (tr <= 0.04045 ? tr / 12.92 : pow((tr + 0.055) / 1.055, 2.4))
                        + 0.7152 * (tg <= 0.04045 ? tg / 12.92 : pow((tg + 0.055) / 1.055, 2.4))
                        + 0.0722 * (tb <= 0.04045 ? tb / 12.92 : pow((tb + 0.055) / 1.055, 2.4));
              double hi = rl > bg_lin ? rl : bg_lin, lo = rl > bg_lin ? bg_lin : rl;
              double cr = (hi + 0.05) / (lo + 0.05);
              printf("gles_render: bare k=%d bg=%s ink=%.2f -> rgb=(%d,%d,%d) cr=%.2f\n",
                     kinds[ki], bg_cases[bi_i].name, ink, spx[idx + 0], spx[idx + 1], spx[idx + 2], cr);
              CHECK(cr >= 4.5);
              if (bi_i == 3) { CHECK(rl < 0.05); } // #F00080 exact WCAG Lbg=0.2008 >= 0.1792 -> picks dark ink
            }
            free(spx);
          }
        }
      }
      // Bare text over a bright (left) / dark (right) boundary: two texts each take their own ink, and one 300pt text
      // across it takes one ink for all its glyphs (no single letter flipped against its neighbours)
      {
        int w_save = cur_w, h_save = cur_h, fbw_save = fb_w, fbh_save = fb_h;
        double sc_save = cur_scale;
        GLuint wt_tex = 0, wt_fb = 0;
        glGenTextures(1, &wt_tex);
        glBindTexture(GL_TEXTURE_2D, wt_tex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 400, 120, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glGenFramebuffers(1, &wt_fb);
        glBindFramebuffer(GL_FRAMEBUFFER, wt_fb);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, wt_tex, 0);
        target_fb = wt_fb; fb_w = 400; fb_h = 120; cur_w = 400; cur_h = 120; cur_scale = 1.0;

        double wt[5 * MB_INST];
        rect_at(wt, 0, 0, 200, 120, 0, 0.96, 0.96, 0.96, 0);
        rect_at(wt + MB_INST, 200, 0, 200, 120, 0, 0.10, 0.10, 0.10, 0);
        rect_at(wt + 2 * MB_INST, 0, 0, 400, 68.0, 5, 1.0, 1.0, 1.0, -48);
        wt[2 * MB_INST + 6] = 1.0; wt[2 * MB_INST + 7] = 8.5; wt[2 * MB_INST + 11] = 0.0; wt[2 * MB_INST + 15] = 1.0;
        wt[2 * MB_INST + 22] = -1.0; wt[2 * MB_INST + 54] = 68.0; wt[2 * MB_INST + 55] = 40.0;
        // Two texts: one glyph at x=70 (its text's box 40..100), one at x=330 (300..360)
        rect_at(wt + 3 * MB_INST, 64, 14, 12, 12, 7, 0.11, 0.11, 0.11, 0);
        wt[3 * MB_INST + 12] = 16.0; wt[3 * MB_INST + 13] = 16.0; wt[3 * MB_INST + 14] = 16.0; wt[3 * MB_INST + 15] = 16.0;
        wt[3 * MB_INST + 21] = 70.0; wt[3 * MB_INST + 22] = 20.0; wt[3 * MB_INST + 23] = bare_ink(30, 10);
        rect_at(wt + 4 * MB_INST, 324, 14, 12, 12, 7, 0.11, 0.11, 0.11, 0);
        wt[4 * MB_INST + 12] = 16.0; wt[4 * MB_INST + 13] = 16.0; wt[4 * MB_INST + 14] = 16.0; wt[4 * MB_INST + 15] = 16.0;
        wt[4 * MB_INST + 21] = 330.0; wt[4 * MB_INST + 22] = 20.0; wt[4 * MB_INST + 23] = bare_ink(30, 10);
        for (int i = 0; i < 5; i++) { wt[i * MB_INST + 18] = 400.0; wt[i * MB_INST + 19] = 120.0; }
        glass_forget();
        gl_present(wt, 5, 0.10, 0.10, 0.10);
        unsigned char *wpx = pixels_of_fb(wt_fb);
        int row = fb_h - 1 - 20;
        unsigned char *pl = wpx + (row * fb_w + 70) * 4;
        unsigned char *pr = wpx + (row * fb_w + 330) * 4;
        double ll = (0.2126 * pl[0] + 0.7152 * pl[1] + 0.0722 * pl[2]) / 255.0;
        double lr = (0.2126 * pr[0] + 0.7152 * pr[1] + 0.0722 * pr[2]) / 255.0;
        printf("gles_render: bare 300pt title split: left_lum=%.3f right_lum=%.3f\n", ll, lr);
        CHECK(ll <= 0.30);
        CHECK(lr >= 0.70);
        free(wpx);

        // One text 50..350 (centre 200, 150 each way) whose glyphs sit over both sides: one ink for both
        {
          for (int g = 3; g <= 4; g++) {
            wt[g * MB_INST + 21] = 200.0; wt[g * MB_INST + 22] = 20.0; wt[g * MB_INST + 23] = bare_ink(150, 10);
          }
          glass_forget();
          gl_present(wt, 5, 0.10, 0.10, 0.10);
          unsigned char *upx = pixels_of_fb(wt_fb);
          unsigned char *ul = upx + (row * fb_w + 70) * 4;
          unsigned char *ur = upx + (row * fb_w + 330) * 4;
          printf("gles_render: bare one 300pt text across the split: left=(%d,%d,%d) right=(%d,%d,%d)\n",
                 ul[0], ul[1], ul[2], ur[0], ur[1], ur[2]);
          CHECK(ul[0] == ur[0] && ul[1] == ur[1] && ul[2] == ur[2]);
          free(upx);
        }

        // Capsule-free bare text (kind 7, a[23] < 0, no kind 2 veil):
        // Over solid dark -> white ink; over solid light -> dark ink; over split -> uniform single ink, zero veil capsule;
        // Over time (slot 6 = who): smoothly eases ink over ~90ms without jumping and stops settling once landed.
        {
          double bt[5 * MB_INST];
          memcpy(bt, wt, 5 * MB_INST * sizeof(double));
          for (int i = 0; i < 5; i++) { bt[i * MB_INST + 18] = 400.0; bt[i * MB_INST + 19] = 120.0; }
          // Split backdrop: no capsule at gap (x=300 over dark side), both glyphs share uniform ink
          glass_forget();
          gl_present(bt, 5, 0.10, 0.10, 0.10);
          unsigned char *vpx = pixels_of_fb(wt_fb);
          unsigned char *gap = vpx + (row * fb_w + 300) * 4;
          unsigned char *ink_l = vpx + (row * fb_w + 70) * 4, *ink_r = vpx + (row * fb_w + 330) * 4;
          printf("gles_render: bare text capsule-free over split: gap=(%d,%d,%d) ink=(%d,%d,%d)/(%d,%d,%d)\n",
                 gap[0], gap[1], gap[2], ink_l[0], ink_l[1], ink_l[2], ink_r[0], ink_r[1], ink_r[2]);
          CHECK(gap[0] <= 40);  // no light capsule drawn behind gap
          CHECK(ink_l[0] == ink_r[0] && ink_l[1] == ink_r[1] && ink_l[2] == ink_r[2]);
          free(vpx);

          // Temporal easing: solid dark (white ink) -> solid light (dark ink) eases smoothly over frames
          gl_set_fixed_dt(1.0 / 60.0);
          rect_at(bt, 0, 0, 200, 120, 0, 0.10, 0.10, 0.10, 0);
          for (int i = 0; i < 5; i++) { bt[i * MB_INST + 18] = 400.0; bt[i * MB_INST + 19] = 120.0; }
          bt[3 * MB_INST + 6] = 7.0; bt[4 * MB_INST + 6] = 7.0;
          glass_forget();
          gl_present(bt, 5, 0.10, 0.10, 0.10);
          unsigned char *t0 = pixels_of_fb(wt_fb);
          int start_ink = t0[(row * fb_w + 70) * 4];
          free(t0);
          // Switch backdrop to solid light
          rect_at(bt, 0, 0, 200, 120, 0, 0.96, 0.96, 0.96, 0);
          rect_at(bt + MB_INST, 200, 0, 200, 120, 0, 0.96, 0.96, 0.96, 0);
          for (int i = 0; i < 5; i++) { bt[i * MB_INST + 18] = 400.0; bt[i * MB_INST + 19] = 120.0; }
          int seen[40], settling_mid = 0;
          for (int fr = 0; fr < 40; fr++) {
            gl_present(bt, 5, 0.96, 0.96, 0.96);
            unsigned char *tp = pixels_of_fb(wt_fb);
            seen[fr] = tp[(row * fb_w + 70) * 4];
            free(tp);
            if (fr == 6) settling_mid = gl_adaptive_settling();
          }
          for (int fr = 0; fr < 30; fr++) gl_present(bt, 5, 0.96, 0.96, 0.96);
          int settling_after = gl_adaptive_settling();
          gl_set_fixed_dt(0.0);
          printf("gles_render: bare text 90ms ease: start=%d f0=%d f5=%d f39=%d settling=%d/%d\n",
                 start_ink, seen[0], seen[5], seen[39], settling_mid, settling_after);
          CHECK(start_ink >= 220);
          CHECK(seen[0] < start_ink - 5 && seen[0] > seen[39] + 20);
          CHECK(seen[5] < seen[0] && seen[39] <= 45);
          CHECK(settling_mid == 1 && settling_after == 0);
        }

        // Apple .soft progressive blur (kind 5, a[22] = -1.0, col.a = 0.96):
        // Same-polarity backdrop -> matches dark ground; opposite-polarity white -> dissolves smoothly at top, fades at bottom.
        // Plus P1-1 regression: more_contrast dark glass (tint_a = 0.52 -> is_dark == 2) over white must densify!
        {
          double ap[2 * MB_INST];
          memset(ap, 0, sizeof(ap));
          rect_at(ap, 0, 0, 400, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(ap + MB_INST, 0, 0, 400, 68.0, 5, 0.08, 0.08, 0.08, -56);
          ap[MB_INST + 6] = 1.0; ap[MB_INST + 7] = 12.0; ap[MB_INST + 11] = 0.96; ap[MB_INST + 15] = 1.0;
          ap[MB_INST + 22] = -1.0; ap[MB_INST + 54] = 68.0; ap[MB_INST + 55] = 20.0;
          for (int i = 0; i < 2; i++) { ap[i * MB_INST + 18] = 400.0; ap[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(ap, 2, 0.08, 0.08, 0.08);
          unsigned char *px_same = pixels_of_fb(wt_fb);
          unsigned char *ps = px_same + ((fb_h - 1 - 16) * fb_w + 200) * 4;
          int same_r = ps[0];
          free(px_same);

          rect_at(ap, 0, 0, 400, 120, 0, 1.0, 1.0, 1.0, 0);
          for (int i = 0; i < 2; i++) { ap[i * MB_INST + 18] = 400.0; ap[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(ap, 2, 1.0, 1.0, 1.0);
          unsigned char *px_opp = pixels_of_fb(wt_fb);
          unsigned char *po_top = px_opp + ((fb_h - 1 - 10) * fb_w + 200) * 4;
          unsigned char *po_bot = px_opp + ((fb_h - 1 - 65) * fb_w + 200) * 4;
          int opp_top_r = po_top[0], opp_bot_r = po_bot[0];
          free(px_opp);
          printf("gles_render: soft_prog_blur dark_on_dark=%d dark_on_white_top=%d bot=%d\n",
                 same_r, opp_top_r, opp_bot_r);
          CHECK(abs(same_r - 20) <= 3);
          CHECK(opp_top_r <= 45);
          CHECK(opp_bot_r >= 225);

          // P1-1 regression: more_contrast dark glass (tint_a = 0.52 -> is_dark == 2) over white
          double mc[2 * MB_INST];
          memset(mc, 0, sizeof(mc));
          rect_at(mc, 0, 0, 400, 120, 0, 1.0, 1.0, 1.0, 0);
          rect_at(mc + MB_INST, 120, 20, 160, 80, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -57);
          mc[MB_INST + 4] = 20.0; mc[MB_INST + 6] = 1.0; mc[MB_INST + 7] = 2.0;
          mc[MB_INST + 11] = 0.52; mc[MB_INST + 12] = 0.0; mc[MB_INST + 13] = 10.0;
          mc[MB_INST + 14] = -1.0; mc[MB_INST + 15] = 1.0;
          for (int i = 0; i < 2; i++) { mc[i * MB_INST + 18] = 400.0; mc[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(mc, 2, 1.0, 1.0, 1.0);
          unsigned char *px_mc = pixels_of_fb(wt_fb);
          int mc_r = px_mc[((fb_h - 1 - 60) * fb_w + 200) * 4];
          free(px_mc);
          printf("gles_render: dark_more_contrast_white r=%d (must densify <= 112)\n", mc_r);
          CHECK(mc_r >= 60 && mc_r <= 112);

          // P1-1 / R4 multi-frame easing regression: is_dark == 2 (tint_a = 0.52) switching dark -> white eases smoothly
          // instead of snapping, and converges to densified dark glass with settling == 0.
          gl_set_fixed_dt(1.0 / 60.0);
          rect_at(mc, 0, 0, 400, 120, 0, 0.05, 0.05, 0.05, 0);
          glass_forget();
          gl_present(mc, 2, 0.05, 0.05, 0.05);
          rect_at(mc, 0, 0, 400, 120, 0, 1.0, 1.0, 1.0, 0);
          gl_present(mc, 2, 1.0, 1.0, 1.0);
          CHECK(gl_adaptive_settling() == 1);
          unsigned char *px_mc1 = pixels_of_fb(wt_fb);
          int mc_f1 = px_mc1[((fb_h - 1 - 60) * fb_w + 200) * 4];
          free(px_mc1);
          for (int k = 0; k < 40; k++) gl_present(mc, 2, 1.0, 1.0, 1.0);
          unsigned char *px_mc40 = pixels_of_fb(wt_fb);
          int mc_f40 = px_mc40[((fb_h - 1 - 60) * fb_w + 200) * 4];
          free(px_mc40);
          printf("gles_render: dark_more_contrast_ease f1=%d f40=%d settling=%d\n",
                 mc_f1, mc_f40, gl_adaptive_settling());
          CHECK(mc_f40 < mc_f1 - 3);
          CHECK(mc_f40 >= 60 && mc_f40 <= 112);
          CHECK(gl_adaptive_settling() == 0);
          gl_set_fixed_dt(0.0);
        }

        // Vertical split multiline bare kind==7: same column, top row y=14..26 over light 0.96, bottom row y=84..96 over dark 0.10,
        // two texts (one a row) each sampling its own box -> both reach CR >= 4.5
        {
          double ml[5 * MB_INST];
          rect_at(ml, 0, 0, 400, 60, 0, 0.96, 0.96, 0.96, 0);
          rect_at(ml + MB_INST, 0, 60, 400, 60, 0, 0.10, 0.10, 0.10, 0);
          rect_at(ml + 2 * MB_INST, 0, 0, 400, 120.0, 5, 1.0, 1.0, 1.0, -52);
          ml[2 * MB_INST + 6] = 1.0; ml[2 * MB_INST + 7] = 4.0; ml[2 * MB_INST + 11] = 0.0; ml[2 * MB_INST + 15] = 1.0;
          ml[2 * MB_INST + 22] = -1.0; ml[2 * MB_INST + 54] = 120.0; ml[2 * MB_INST + 55] = 20.0;
          rect_at(ml + 3 * MB_INST, 94, 14, 12, 12, 7, 0.11, 0.11, 0.11, 0);
          ml[3 * MB_INST + 12] = 16.0; ml[3 * MB_INST + 13] = 16.0; ml[3 * MB_INST + 14] = 16.0; ml[3 * MB_INST + 15] = 16.0;
          ml[3 * MB_INST + 21] = 100.0; ml[3 * MB_INST + 22] = 20.0; ml[3 * MB_INST + 23] = bare_ink(30, 8);
          rect_at(ml + 4 * MB_INST, 94, 84, 12, 12, 7, 0.11, 0.11, 0.11, 0);
          ml[4 * MB_INST + 12] = 16.0; ml[4 * MB_INST + 13] = 16.0; ml[4 * MB_INST + 14] = 16.0; ml[4 * MB_INST + 15] = 16.0;
          ml[4 * MB_INST + 21] = 100.0; ml[4 * MB_INST + 22] = 90.0; ml[4 * MB_INST + 23] = bare_ink(30, 8);
          for (int i = 0; i < 5; i++) { ml[i * MB_INST + 18] = 400.0; ml[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(ml, 5, 0.10, 0.10, 0.10);
          unsigned char *mpx = pixels_of_fb(wt_fb);
          unsigned char *pt = mpx + ((fb_h - 1 - 20) * fb_w + 100) * 4;
          unsigned char *pb2 = mpx + ((fb_h - 1 - 90) * fb_w + 100) * 4;
          double yt = wcag_luma_u8(pt[0], pt[1], pt[2]);
          double yb = wcag_luma_u8(pb2[0], pb2[1], pb2[2]);
          double bg_top = wcag_luma_u8(245, 245, 245), bg_bot = wcag_luma_u8(26, 26, 26);
          double cr_top = ((yt > bg_top ? yt : bg_top) + 0.05) / ((yt > bg_top ? bg_top : yt) + 0.05);
          double cr_bot = ((yb > bg_bot ? yb : bg_bot) + 0.05) / ((yb > bg_bot ? bg_bot : yb) + 0.05);
          printf("gles_render: bare multiline k=7 top_cr=%.2f bot_cr=%.2f\n", cr_top, cr_bot);
          CHECK(cr_top >= 4.5 && cr_bot >= 4.5);
          free(mpx);
        }

        // Single-band bare kind==11 with legal p.zw=(0,0) at x=80 over light 0.96, ancestor pad.yz=(340,20) over dark 0.10
        {
          double s11[5 * MB_INST];
          rect_at(s11, 0, 0, 200, 120, 0, 0.96, 0.96, 0.96, 0);
          rect_at(s11 + MB_INST, 200, 0, 200, 120, 0, 0.10, 0.10, 0.10, 0);
          rect_at(s11 + 2 * MB_INST, 0, 0, 400, 68.0, 5, 1.0, 1.0, 1.0, -53);
          s11[2 * MB_INST + 6] = 1.0; s11[2 * MB_INST + 7] = 4.0; s11[2 * MB_INST + 11] = 0.0; s11[2 * MB_INST + 15] = 1.0;
          s11[2 * MB_INST + 22] = -1.0; s11[2 * MB_INST + 54] = 68.0; s11[2 * MB_INST + 55] = 20.0;
          rect_at(s11 + 3 * MB_INST, 72, 12, 16, 16, 11, 0.93, 0.93, 0.93, 0);
          s11[3 * MB_INST + 4] = 0.0; s11[3 * MB_INST + 6] = 0.0; s11[3 * MB_INST + 7] = 0.0;
          s11[3 * MB_INST + 12] = 0.0; s11[3 * MB_INST + 13] = 4.0; s11[3 * MB_INST + 14] = 0.0;
          s11[3 * MB_INST + 21] = 340.0; s11[3 * MB_INST + 22] = 20.0; s11[3 * MB_INST + 23] = -12.0;
          memset(s11 + 4 * MB_INST, 0, MB_INST * sizeof(double));
          s11[4 * MB_INST + 5] = 12.0;
          s11[4 * MB_INST + 0] = 0.0; s11[4 * MB_INST + 1] = 0.0; s11[4 * MB_INST + 2] = 1.0; s11[4 * MB_INST + 3] = 0.0;
          s11[4 * MB_INST + 8] = 1.0; s11[4 * MB_INST + 9] = 0.0; s11[4 * MB_INST + 10] = 1.0; s11[4 * MB_INST + 11] = 1.0;
          s11[4 * MB_INST + 12] = 1.0; s11[4 * MB_INST + 13] = 1.0; s11[4 * MB_INST + 14] = 0.0; s11[4 * MB_INST + 15] = 1.0;
          s11[4 * MB_INST + 16] = 0.0; s11[4 * MB_INST + 17] = 1.0; s11[4 * MB_INST + 18] = 0.0; s11[4 * MB_INST + 19] = 0.0;
          for (int i = 0; i < 4; i++) { s11[i * MB_INST + 18] = 400.0; s11[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(s11, 5, 0.10, 0.10, 0.10);
          unsigned char *p11 = pixels_of_fb(wt_fb);
          unsigned char *c11 = p11 + ((fb_h - 1 - 20) * fb_w + 80) * 4;
          double y11 = wcag_luma_u8(c11[0], c11[1], c11[2]);
          double bg_l = wcag_luma_u8(245, 245, 245);
          double cr11 = ((bg_l > y11 ? bg_l : y11) + 0.05) / ((bg_l > y11 ? y11 : bg_l) + 0.05);
          printf("gles_render: bare k=11 zero-offset rgb=(%d,%d,%d) cr=%.2f\n", c11[0], c11[1], c11[2], cr11);
          CHECK(y11 < 0.20 && cr11 >= 4.5);
          free(p11);
        }

        // Merged liquid glass (pad.w=8.0) on left light 0.96 + bare kind==10 icon on right dark 0.10: grab_of must expand capture
        {
          double mlq[4 * MB_INST];
          rect_at(mlq, 0, 0, 200, 120, 0, 0.96, 0.96, 0.96, 0);
          rect_at(mlq + MB_INST, 200, 0, 200, 120, 0, 0.10, 0.10, 0.10, 0);
          rect_at(mlq + 2 * MB_INST, 10, 10, 40, 28, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -54);
          mlq[2 * MB_INST + 4] = 14.0; mlq[2 * MB_INST + 6] = 1.0; mlq[2 * MB_INST + 7] = 2.0;
          mlq[2 * MB_INST + 11] = 0x67 / 255.0; mlq[2 * MB_INST + 14] = -1.0; mlq[2 * MB_INST + 15] = 1.0;
          mlq[2 * MB_INST + 23] = 8.0; // merged_liquid
          rect_at(mlq + 3 * MB_INST, 300, 14, 16, 12, 10, 0.11, 0.11, 0.11, 0);
          mlq[3 * MB_INST + 4] = 4.0;
          mlq[3 * MB_INST + 12] = 0.1; mlq[3 * MB_INST + 13] = 0.5; mlq[3 * MB_INST + 14] = 0.9; mlq[3 * MB_INST + 15] = 0.5;
          mlq[3 * MB_INST + 21] = 308.0; mlq[3 * MB_INST + 22] = 20.0; mlq[3 * MB_INST + 23] = -12.0;
          for (int i = 0; i < 4; i++) { mlq[i * MB_INST + 18] = 400.0; mlq[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(mlq, 4, 0.10, 0.10, 0.10);
          unsigned char *pm = pixels_of_fb(wt_fb);
          unsigned char *cm = pm + ((fb_h - 1 - 20) * fb_w + 308) * 4;
          double ym = wcag_luma_u8(cm[0], cm[1], cm[2]);
          double bg_d = wcag_luma_u8(26, 26, 26);
          double crm = ((ym > bg_d ? ym : bg_d) + 0.05) / ((ym > bg_d ? bg_d : ym) + 0.05);
          printf("gles_render: bare k=10 after merged_liquid rgb=(%d,%d,%d) cr=%.2f\n", cm[0], cm[1], cm[2], crm);
          CHECK(ym > 0.55 && crm >= 4.5);
          free(pm);
        }

        // Warm-cache vs cold-cache parity (fixed clear color; changing patch strictly outside 2nd glass capture box,
        // inside bare kind==10 icon sample rect): verify control frame cache hit, cold_before != cold_after (>=30),
        // and warm_after == cold_after (<=1)
        {
          double hc[6 * MB_INST];
          rect_at(hc, 0, 0, 200, 120, 0, 0.96, 0.96, 0.96, 0);
          rect_at(hc + MB_INST, 200, 0, 200, 120, 0, 0.40, 0.40, 0.40, 0);
          // Changing patch at x=266..293 (width 27 -> reaches right=295, strictly outside 2nd glass reaches left=295,
          // covers bare icon leftmost sample 306 - 2*0.38*20 = 290.8)
          rect_at(hc + 2 * MB_INST, 266, 0, 27, 120, 0, 0.10, 0.10, 0.10, 0);
          rect_at(hc + 3 * MB_INST, 10, 10, 40, 28, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -49);
          hc[3 * MB_INST + 4] = 14.0; hc[3 * MB_INST + 6] = 1.0; hc[3 * MB_INST + 7] = 2.0;
          hc[3 * MB_INST + 11] = 0x67 / 255.0; hc[3 * MB_INST + 14] = -1.0; hc[3 * MB_INST + 15] = 1.0;
          // Bare icon x=298..314 (center 306, pad.w=-40 -> half-width 20, right edge 310..314 under 2nd glass)
          rect_at(hc + 4 * MB_INST, 298, 14, 16, 12, 10, 0.11, 0.11, 0.11, 0);
          hc[4 * MB_INST + 4] = 4.0;
          hc[4 * MB_INST + 12] = 0.1; hc[4 * MB_INST + 13] = 0.5; hc[4 * MB_INST + 14] = 0.9; hc[4 * MB_INST + 15] = 0.5;
          hc[4 * MB_INST + 21] = 306.0; hc[4 * MB_INST + 22] = 20.0; hc[4 * MB_INST + 23] = -40.0;
          // 2nd glass x=310..350 (blur=4.0, margin=14 -> capture left=296)
          rect_at(hc + 5 * MB_INST, 310, 6, 40, 32, 5, 1.0, 1.0, 1.0, -50);
          hc[5 * MB_INST + 6] = 1.0; hc[5 * MB_INST + 7] = 4.0; hc[5 * MB_INST + 11] = 0.10; hc[5 * MB_INST + 15] = 1.0;
          for (int i = 0; i < 6; i++) { hc[i * MB_INST + 18] = 400.0; hc[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(hc, 6, 0.40, 0.40, 0.40);
          unsigned char *cold_before = pixels_of_fb(wt_fb);
          // Unchanged control frame: verifies cache hit with 0 diff
          gl_present(hc, 6, 0.40, 0.40, 0.40);
          unsigned char *ctrl_px = pixels_of_fb(wt_fb);
          int ctrl_diff = 0;
          for (int y = 6; y < 38; y++) {
            for (int x = 310; x < 350; x++) {
              int idx = ((fb_h - 1 - y) * fb_w + x) * 4;
              for (int c = 0; c < 3; c++) {
                int d = abs((int)cold_before[idx + c] - (int)ctrl_px[idx + c]);
                if (d > ctrl_diff) ctrl_diff = d;
              }
            }
          }
          // Now flip ONLY the patch outside 2nd glass capture box (clear color stays fixed 0.40)
          hc[2 * MB_INST + 8] = 1.0; hc[2 * MB_INST + 9] = 1.0; hc[2 * MB_INST + 10] = 1.0;
          gl_present(hc, 6, 0.40, 0.40, 0.40);
          unsigned char *warm_after = pixels_of_fb(wt_fb);
          glass_forget();
          gl_present(hc, 6, 0.40, 0.40, 0.40);
          unsigned char *cold_after = pixels_of_fb(wt_fb);
          int delta_cold = 0, max_diff = 0;
          for (int y = 6; y < 38; y++) {
            for (int x = 310; x < 350; x++) {
              int idx = ((fb_h - 1 - y) * fb_w + x) * 4;
              for (int c = 0; c < 3; c++) {
                int dc = abs((int)cold_before[idx + c] - (int)cold_after[idx + c]);
                if (dc > delta_cold) delta_cold = dc;
                int dw = abs((int)warm_after[idx + c] - (int)cold_after[idx + c]);
                if (dw > max_diff) max_diff = dw;
              }
            }
          }
          printf("gles_render: bare k=10 warm vs cold 2nd-glass ctrl_diff=%d cold_delta=%d warm_vs_cold=%d\n",
                 ctrl_diff, delta_cold, max_diff);
          CHECK(ctrl_diff == 0 && delta_cold >= 30 && max_diff <= 1);
          free(cold_before); free(ctrl_px); free(warm_after); free(cold_after);
        }

        // Dark-mode adaptive=true pill (0x20202067) full grayscale round-trip sweep (ascending & descending):
        // verifies hysteresis latch in b-channel keeps CR >= 3.0 at EVERY gray level including #B8B8B8/#B9B9B9
        {
          const double grays[] = {
            0.0, 0.25, 0x80/255.0, 0x99/255.0, 0xA8/255.0, 0xB8/255.0, 0xB9/255.0, 0xCC/255.0, 1.0,
            0xCC/255.0, 0xB9/255.0, 0xB8/255.0, 0xA8/255.0, 0x99/255.0, 0x80/255.0, 0.25, 0.0
          };
          int ng = (int)(sizeof(grays) / sizeof(grays[0]));
          double dp[3 * MB_INST];
          rect_at(dp, 0, 0, 400, 120, 0, 0.0, 0.0, 0.0, 0);
          rect_at(dp + MB_INST, 150, 20, 100, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -51);
          dp[MB_INST + 4] = 18.0; dp[MB_INST + 6] = 1.0; dp[MB_INST + 7] = 1.2;
          dp[MB_INST + 11] = 0x67 / 255.0; dp[MB_INST + 12] = 0.6; dp[MB_INST + 13] = 14.0;
          dp[MB_INST + 14] = -1.0; dp[MB_INST + 15] = 1.0;
          dp[MB_INST + 21] = 20.0; dp[MB_INST + 22] = 0.06; dp[MB_INST + 23] = 0.0;
          rect_at(dp + 2 * MB_INST, 192, 32, 16, 12, 10, 0.93, 0.93, 0.93, 0);
          dp[2 * MB_INST + 4] = 4.0;
          dp[2 * MB_INST + 12] = 0.1; dp[2 * MB_INST + 13] = 0.5; dp[2 * MB_INST + 14] = 0.9; dp[2 * MB_INST + 15] = 0.5;
          dp[2 * MB_INST + 21] = 200.0; dp[2 * MB_INST + 22] = 38.0; dp[2 * MB_INST + 23] = 18.0;
          for (int i = 0; i < 3; i++) { dp[i * MB_INST + 18] = 400.0; dp[i * MB_INST + 19] = 120.0; }
          glass_forget();
          double prev_dt = ad_fixed_dt;
          ad_fixed_dt = 1.0;
          double min_cr = 999.0;
          for (int gi = 0; gi < ng; gi++) {
            double gv = grays[gi];
            dp[8] = gv; dp[9] = gv; dp[10] = gv;
            gl_present(dp, 3, gv, gv, gv);
            unsigned char *dpx = pixels_of_fb(wt_fb);
            int r38 = fb_h - 1 - 38;
            unsigned char *gp2 = dpx + (r38 * fb_w + 170) * 4;
            unsigned char *ip2 = dpx + (r38 * fb_w + 200) * 4;
            double gl2 = wcag_luma_u8(gp2[0], gp2[1], gp2[2]);
            double il2 = wcag_luma_u8(ip2[0], ip2[1], ip2[2]);
            double dcr = ((il2 > gl2 ? il2 : gl2) + 0.05) / ((il2 > gl2 ? gl2 : il2) + 0.05);
            if (dcr < min_cr) min_cr = dcr;
            if (dcr < 4.5) {
              printf("gles_render: FAIL dark pill step=%d gray=#%02X glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                     gi, (int)(gv * 255.0 + 0.5), gp2[0], gp2[1], gp2[2], ip2[0], ip2[1], ip2[2], dcr);
            }
            CHECK(dcr >= 4.5);
            free(dpx);
          }
          ad_fixed_dt = prev_dt;
          printf("gles_render: dark adaptive pill round-trip grayscale sweep (%d steps) min_cr=%.2f\n", ng, min_cr);
        }

        // Dark-mode adaptive pill straddling left dark (0.08) + right coral (0.95, 0.65, 0.55):
        // same-pixel glass vs icon contrast must be >= 4.5
        {
          double sc_p[4 * MB_INST];
          rect_at(sc_p, 0, 0, 180, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(sc_p + MB_INST, 180, 0, 220, 120, 0, 0.95, 0.65, 0.55, 0);
          rect_at(sc_p + 2 * MB_INST, 152, 18, 48, 40, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -55);
          sc_p[2 * MB_INST + 4] = 20.0; sc_p[2 * MB_INST + 6] = 1.0; sc_p[2 * MB_INST + 7] = 1.2;
          sc_p[2 * MB_INST + 11] = 0x67 / 255.0; sc_p[2 * MB_INST + 12] = 0.6; sc_p[2 * MB_INST + 13] = 14.0;
          sc_p[2 * MB_INST + 14] = -1.0; sc_p[2 * MB_INST + 15] = 1.0;
          sc_p[2 * MB_INST + 21] = 20.0; sc_p[2 * MB_INST + 22] = 0.06; sc_p[2 * MB_INST + 23] = 0.0;
          rect_at(sc_p + 3 * MB_INST, 184, 32, 12, 12, 10, 0.93, 0.93, 0.93, 0);
          sc_p[3 * MB_INST + 4] = 4.0;
          sc_p[3 * MB_INST + 12] = 0.1; sc_p[3 * MB_INST + 13] = 0.5; sc_p[3 * MB_INST + 14] = 0.9; sc_p[3 * MB_INST + 15] = 0.5;
          sc_p[3 * MB_INST + 21] = 176.0; sc_p[3 * MB_INST + 22] = 38.0; sc_p[3 * MB_INST + 23] = 20.0;
          for (int i = 0; i < 4; i++) { sc_p[i * MB_INST + 18] = 400.0; sc_p[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(sc_p, 3, 0.08, 0.08, 0.08);
          unsigned char *bgx = pixels_of_fb(wt_fb);
          glass_forget();
          gl_present(sc_p, 4, 0.08, 0.08, 0.08);
          unsigned char *spx = pixels_of_fb(wt_fb);
          int r38 = fb_h - 1 - 38;
          unsigned char *gp3 = bgx + (r38 * fb_w + 190) * 4;
          unsigned char *ip3 = spx + (r38 * fb_w + 190) * 4;
          double gl3 = wcag_luma_u8(gp3[0], gp3[1], gp3[2]);
          double il3 = wcag_luma_u8(ip3[0], ip3[1], ip3[2]);
          double scr = ((il3 > gl3 ? il3 : gl3) + 0.05) / ((il3 > gl3 ? gl3 : il3) + 0.05);
          printf("gles_render: dark adaptive straddle dark+coral: glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 gp3[0], gp3[1], gp3[2], ip3[0], ip3[1], ip3[2], scr);
          CHECK(scr >= 4.5);
          free(bgx); free(spx);
        }

        // R3-1A: Dark capsule straddling left white (1.0) + right dark gray (0.08), icon in right dark zone -> stays bright white (CR >= 4.5)
        {
          double wd_p[4 * MB_INST];
          rect_at(wd_p, 0, 0, 172, 120, 0, 1.0, 1.0, 1.0, 0);
          rect_at(wd_p + MB_INST, 172, 0, 228, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(wd_p + 2 * MB_INST, 152, 18, 48, 40, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -56);
          wd_p[2 * MB_INST + 4] = 20.0; wd_p[2 * MB_INST + 6] = 1.0; wd_p[2 * MB_INST + 7] = 1.2;
          wd_p[2 * MB_INST + 11] = 0x67 / 255.0; wd_p[2 * MB_INST + 12] = 0.6; wd_p[2 * MB_INST + 13] = 14.0;
          wd_p[2 * MB_INST + 14] = -1.0; wd_p[2 * MB_INST + 15] = 1.0;
          wd_p[2 * MB_INST + 21] = 20.0; wd_p[2 * MB_INST + 22] = 0.06; wd_p[2 * MB_INST + 23] = 0.0;
          rect_at(wd_p + 3 * MB_INST, 184, 32, 12, 12, 10, 0.93, 0.93, 0.93, 0);
          wd_p[3 * MB_INST + 4] = 4.0;
          wd_p[3 * MB_INST + 12] = 0.1; wd_p[3 * MB_INST + 13] = 0.5; wd_p[3 * MB_INST + 14] = 0.9; wd_p[3 * MB_INST + 15] = 0.5;
          wd_p[3 * MB_INST + 21] = 176.0; wd_p[3 * MB_INST + 22] = 38.0; wd_p[3 * MB_INST + 23] = 20.0;
          for (int i = 0; i < 4; i++) { wd_p[i * MB_INST + 18] = 400.0; wd_p[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(wd_p, 3, 0.08, 0.08, 0.08);
          unsigned char *bgx = pixels_of_fb(wt_fb);
          glass_forget();
          gl_present(wd_p, 4, 0.08, 0.08, 0.08);
          unsigned char *px = pixels_of_fb(wt_fb);
          unsigned char *gp = bgx + ((fb_h - 1 - 38) * fb_w + 190) * 4;
          unsigned char *ip = px + ((fb_h - 1 - 38) * fb_w + 190) * 4;
          double gl = wcag_luma_u8(gp[0], gp[1], gp[2]), il = wcag_luma_u8(ip[0], ip[1], ip[2]);
          double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
          printf("gles_render: dark adaptive straddle white+dark right-icon: glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 gp[0], gp[1], gp[2], ip[0], ip[1], ip[2], cr);
          CHECK(cr >= 4.5);
          free(bgx); free(px);
        }

        // R3-1B: Light adaptive capsule on uniform dark gray (0.08) + light neutral icon -> stays bright white (no b-channel collision)
        {
          double ld_p[3 * MB_INST];
          rect_at(ld_p, 0, 0, 400, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(ld_p + MB_INST, 150, 20, 100, 36, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -57);
          ld_p[MB_INST + 4] = 18.0; ld_p[MB_INST + 6] = -1.0; ld_p[MB_INST + 7] = 1.2;
          ld_p[MB_INST + 11] = 0x67 / 255.0; ld_p[MB_INST + 12] = 0.6; ld_p[MB_INST + 13] = 14.0;
          ld_p[MB_INST + 14] = -1.0; ld_p[MB_INST + 15] = 1.0;
          ld_p[MB_INST + 21] = 20.0; ld_p[MB_INST + 22] = 0.06; ld_p[MB_INST + 23] = 0.0;
          rect_at(ld_p + 2 * MB_INST, 192, 32, 16, 12, 10, 0.93, 0.93, 0.93, 0);
          ld_p[2 * MB_INST + 4] = 4.0;
          ld_p[2 * MB_INST + 12] = 0.1; ld_p[2 * MB_INST + 13] = 0.5; ld_p[2 * MB_INST + 14] = 0.9; ld_p[2 * MB_INST + 15] = 0.5;
          ld_p[2 * MB_INST + 21] = 200.0; ld_p[2 * MB_INST + 22] = 38.0; ld_p[2 * MB_INST + 23] = 18.0;
          for (int i = 0; i < 3; i++) { ld_p[i * MB_INST + 18] = 400.0; ld_p[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(ld_p, 3, 0.08, 0.08, 0.08);
          unsigned char *px = pixels_of_fb(wt_fb);
          unsigned char *gp = px + ((fb_h - 1 - 38) * fb_w + 170) * 4;
          unsigned char *ip = px + ((fb_h - 1 - 38) * fb_w + 200) * 4;
          double gl = wcag_luma_u8(gp[0], gp[1], gp[2]), il = wcag_luma_u8(ip[0], ip[1], ip[2]);
          double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
          printf("gles_render: light adaptive on dark + light icon: glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 gp[0], gp[1], gp[2], ip[0], ip[1], ip[2], cr);
          CHECK(il > 0.70 && cr >= 4.5);
          free(px);
        }

        // R3-1C: 4-frame hysteresis jitter test (zero flicker): (1) #9A/#9B straddle, (2) #7A/#7B inside [0.20, 0.26] band
        {
          double jt[4 * MB_INST];
          rect_at(jt, 0, 0, 180, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(jt + MB_INST, 180, 0, 220, 120, 0, 0x9A/255.0, 0x9A/255.0, 0x9A/255.0, 0);
          rect_at(jt + 2 * MB_INST, 152, 18, 48, 40, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -58);
          jt[2 * MB_INST + 4] = 20.0; jt[2 * MB_INST + 6] = 1.0; jt[2 * MB_INST + 7] = 1.2;
          jt[2 * MB_INST + 11] = 0x67 / 255.0; jt[2 * MB_INST + 12] = 0.6; jt[2 * MB_INST + 13] = 14.0;
          jt[2 * MB_INST + 14] = -1.0; jt[2 * MB_INST + 15] = 1.0;
          jt[2 * MB_INST + 21] = 20.0; jt[2 * MB_INST + 22] = 0.06; jt[2 * MB_INST + 23] = 0.0;
          rect_at(jt + 3 * MB_INST, 184, 32, 12, 12, 10, 0.93, 0.93, 0.93, 0);
          jt[3 * MB_INST + 4] = 4.0;
          jt[3 * MB_INST + 12] = 0.1; jt[3 * MB_INST + 13] = 0.5; jt[3 * MB_INST + 14] = 0.9; jt[3 * MB_INST + 15] = 0.5;
          jt[3 * MB_INST + 21] = 176.0; jt[3 * MB_INST + 22] = 38.0; jt[3 * MB_INST + 23] = 20.0;
          for (int i = 0; i < 4; i++) { jt[i * MB_INST + 18] = 400.0; jt[i * MB_INST + 19] = 120.0; }
          const double seq1[4] = { 0x9A/255.0, 0x9B/255.0, 0x9A/255.0, 0x9B/255.0 };
          glass_forget();
          unsigned char ref1[3] = {0, 0, 0};
          int max_j1 = 0;
          for (int f = 0; f < 4; f++) {
            jt[MB_INST + 8] = seq1[f]; jt[MB_INST + 9] = seq1[f]; jt[MB_INST + 10] = seq1[f];
            gl_present(jt, 4, 0.08, 0.08, 0.08);
            unsigned char *px = pixels_of_fb(wt_fb);
            unsigned char *ip = px + ((fb_h - 1 - 38) * fb_w + 190) * 4;
            if (f == 0) { ref1[0] = ip[0]; ref1[1] = ip[1]; ref1[2] = ip[2]; }
            else for (int c = 0; c < 3; c++) { int d = abs((int)ip[c] - (int)ref1[c]); if (d > max_j1) max_j1 = d; }
            free(px);
          }
          // Case 2: warm up dark (0.08 -> b2=0), then 4-frame 1-LSB oscillation inside [0.20, 0.26] (#7A <-> #7B)
          const double seq2[4] = { 0x7A/255.0, 0x7B/255.0, 0x7A/255.0, 0x7B/255.0 };
          glass_forget();
          jt[MB_INST + 8] = 0.08; jt[MB_INST + 9] = 0.08; jt[MB_INST + 10] = 0.08;
          gl_present(jt, 4, 0.08, 0.08, 0.08);
          unsigned char ref2[3] = {0, 0, 0};
          int max_j2 = 0;
          for (int f = 0; f < 4; f++) {
            jt[MB_INST + 8] = seq2[f]; jt[MB_INST + 9] = seq2[f]; jt[MB_INST + 10] = seq2[f];
            gl_present(jt, 4, 0.08, 0.08, 0.08);
            unsigned char *px = pixels_of_fb(wt_fb);
            unsigned char *ip = px + ((fb_h - 1 - 38) * fb_w + 190) * 4;
            if (f == 0) { ref2[0] = ip[0]; ref2[1] = ip[1]; ref2[2] = ip[2]; }
            else for (int c = 0; c < 3; c++) { int d = abs((int)ip[c] - (int)ref2[c]); if (d > max_j2) max_j2 = d; }
            free(px);
          }
          printf("gles_render: dark adaptive 4-frame jitter #9A/#9B diff=%d #7A/#7B diff=%d\n", max_j1, max_j2);
          CHECK(max_j1 == 0 && max_j2 == 0);
        }

        // R3-1D: Text glyphs (kind==7, is_icon==false) inside dark capsule straddling light/dark -> uniform word ink AND CR >= 4.5 on BOTH halves
        {
          double tx_p[5 * MB_INST];
          rect_at(tx_p, 0, 0, 180, 120, 0, 1.0, 1.0, 1.0, 0);
          rect_at(tx_p + MB_INST, 180, 0, 220, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(tx_p + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -59);
          tx_p[2 * MB_INST + 4] = 18.0; tx_p[2 * MB_INST + 6] = 1.0; tx_p[2 * MB_INST + 7] = 1.2;
          tx_p[2 * MB_INST + 11] = 0x67 / 255.0; tx_p[2 * MB_INST + 12] = 0.6; tx_p[2 * MB_INST + 13] = 14.0;
          tx_p[2 * MB_INST + 14] = -1.0; tx_p[2 * MB_INST + 15] = 1.0;
          tx_p[2 * MB_INST + 21] = 20.0; tx_p[2 * MB_INST + 22] = 0.06; tx_p[2 * MB_INST + 23] = 0.0;
          rect_at(tx_p + 3 * MB_INST, 124, 32, 12, 12, 7, 0.93, 0.93, 0.93, 0);
          tx_p[3 * MB_INST + 12] = 16.0; tx_p[3 * MB_INST + 13] = 16.0; tx_p[3 * MB_INST + 14] = 16.0; tx_p[3 * MB_INST + 15] = 16.0;
          tx_p[3 * MB_INST + 21] = 180.0; tx_p[3 * MB_INST + 22] = 38.0; tx_p[3 * MB_INST + 23] = 18.0;
          rect_at(tx_p + 4 * MB_INST, 224, 32, 12, 12, 7, 0.93, 0.93, 0.93, 0);
          tx_p[4 * MB_INST + 12] = 16.0; tx_p[4 * MB_INST + 13] = 16.0; tx_p[4 * MB_INST + 14] = 16.0; tx_p[4 * MB_INST + 15] = 16.0;
          tx_p[4 * MB_INST + 21] = 180.0; tx_p[4 * MB_INST + 22] = 38.0; tx_p[4 * MB_INST + 23] = 18.0;
          for (int i = 0; i < 5; i++) { tx_p[i * MB_INST + 18] = 400.0; tx_p[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(tx_p, 3, 0.08, 0.08, 0.08);
          unsigned char *bgx = pixels_of_fb(wt_fb);
          glass_forget();
          gl_present(tx_p, 5, 0.08, 0.08, 0.08);
          unsigned char *px = pixels_of_fb(wt_fb);
          int r38 = fb_h - 1 - 38;
          unsigned char *bg_l = bgx + (r38 * fb_w + 130) * 4;
          unsigned char *bg_r = bgx + (r38 * fb_w + 230) * 4;
          unsigned char *gl_l = px + (r38 * fb_w + 130) * 4;
          unsigned char *gl_r = px + (r38 * fb_w + 230) * 4;
          int word_diff = 0;
          for (int c = 0; c < 3; c++) { int d = abs((int)gl_l[c] - (int)gl_r[c]); if (d > word_diff) word_diff = d; }
          double ybl = wcag_luma_u8(bg_l[0], bg_l[1], bg_l[2]), yil = wcag_luma_u8(gl_l[0], gl_l[1], gl_l[2]);
          double ybr = wcag_luma_u8(bg_r[0], bg_r[1], bg_r[2]), yir = wcag_luma_u8(gl_r[0], gl_r[1], gl_r[2]);
          double cr_l = ((yil > ybl ? yil : ybl) + 0.05) / ((yil > ybl ? ybl : yil) + 0.05);
          double cr_r = ((yir > ybr ? yir : ybr) + 0.05) / ((yir > ybr ? ybr : yir) + 0.05);
          printf("gles_render: dark adaptive straddle text uniform left_cr=%.2f right_cr=%.2f diff=%d\n", cr_l, cr_r, word_diff);
          CHECK(word_diff <= 1 && cr_l >= 4.5 && cr_r >= 4.5);
          free(bgx); free(px);
        }

        // R4-1E: Wide capsule (x=100..260, split x=216, icon at (238,38)) both directions -> same-pixel CR >= 4.5
        for (int dir = 0; dir < 2; dir++) {
          double lv = dir == 0 ? 1.0 : 0.08;
          double rv = dir == 0 ? 0.08 : 1.0;
          double wc[4 * MB_INST];
          rect_at(wc, 0, 0, 216, 120, 0, lv, lv, lv, 0);
          rect_at(wc + MB_INST, 216, 0, 184, 120, 0, rv, rv, rv, 0);
          rect_at(wc + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -60 - dir);
          wc[2 * MB_INST + 4] = 18.0; wc[2 * MB_INST + 6] = 1.0; wc[2 * MB_INST + 7] = 1.2;
          wc[2 * MB_INST + 11] = 0x67 / 255.0; wc[2 * MB_INST + 12] = 0.6; wc[2 * MB_INST + 13] = 14.0;
          wc[2 * MB_INST + 14] = -1.0; wc[2 * MB_INST + 15] = 1.0;
          wc[2 * MB_INST + 21] = 20.0; wc[2 * MB_INST + 22] = 0.06; wc[2 * MB_INST + 23] = 0.0;
          rect_at(wc + 3 * MB_INST, 232, 32, 12, 12, 10, 0.93, 0.93, 0.93, 0);
          wc[3 * MB_INST + 4] = 4.0;
          wc[3 * MB_INST + 12] = 0.1; wc[3 * MB_INST + 13] = 0.5; wc[3 * MB_INST + 14] = 0.9; wc[3 * MB_INST + 15] = 0.5;
          wc[3 * MB_INST + 21] = 180.0; wc[3 * MB_INST + 22] = 38.0; wc[3 * MB_INST + 23] = 18.0;
          for (int i = 0; i < 4; i++) { wc[i * MB_INST + 18] = 400.0; wc[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(wc, 3, rv, rv, rv);
          unsigned char *bgx = pixels_of_fb(wt_fb);
          glass_forget();
          gl_present(wc, 4, rv, rv, rv);
          unsigned char *px = pixels_of_fb(wt_fb);
          int r38 = fb_h - 1 - 38;
          unsigned char *gp = bgx + (r38 * fb_w + 238) * 4;
          unsigned char *ip = px + (r38 * fb_w + 238) * 4;
          double gl = wcag_luma_u8(gp[0], gp[1], gp[2]), il = wcag_luma_u8(ip[0], ip[1], ip[2]);
          double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
          printf("gles_render: dark adaptive wide off-center dir=%d glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 dir, gp[0], gp[1], gp[2], ip[0], ip[1], ip[2], cr);
          CHECK(cr >= 4.5);
          free(bgx); free(px);
        }

        // R5-1: 60 Hz straddling word transition (right=#141414, left #141414 -> white, dt=1/60, 15 frames):
        // every frame 1..15 must keep left_cr >= 4.5, right_cr >= 4.5, and word_diff <= 1
        {
          double tr[5 * MB_INST];
          rect_at(tr, 0, 0, 180, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(tr + MB_INST, 180, 0, 220, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(tr + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -62);
          tr[2 * MB_INST + 4] = 18.0; tr[2 * MB_INST + 6] = 1.0; tr[2 * MB_INST + 7] = 1.2;
          tr[2 * MB_INST + 11] = 0x67 / 255.0; tr[2 * MB_INST + 12] = 0.6; tr[2 * MB_INST + 13] = 14.0;
          tr[2 * MB_INST + 14] = -1.0; tr[2 * MB_INST + 15] = 1.0;
          tr[2 * MB_INST + 21] = 20.0; tr[2 * MB_INST + 22] = 0.06; tr[2 * MB_INST + 23] = 0.0;
          rect_at(tr + 3 * MB_INST, 124, 32, 12, 12, 7, 0.93, 0.93, 0.93, 0);
          tr[3 * MB_INST + 12] = 16.0; tr[3 * MB_INST + 13] = 16.0; tr[3 * MB_INST + 14] = 16.0; tr[3 * MB_INST + 15] = 16.0;
          tr[3 * MB_INST + 21] = 180.0; tr[3 * MB_INST + 22] = 38.0; tr[3 * MB_INST + 23] = 18.0;
          rect_at(tr + 4 * MB_INST, 224, 32, 12, 12, 7, 0.93, 0.93, 0.93, 0);
          tr[4 * MB_INST + 12] = 16.0; tr[4 * MB_INST + 13] = 16.0; tr[4 * MB_INST + 14] = 16.0; tr[4 * MB_INST + 15] = 16.0;
          tr[4 * MB_INST + 21] = 180.0; tr[4 * MB_INST + 22] = 38.0; tr[4 * MB_INST + 23] = 18.0;
          for (int i = 0; i < 5; i++) { tr[i * MB_INST + 18] = 400.0; tr[i * MB_INST + 19] = 120.0; }
          double prev_dt = ad_fixed_dt;
          ad_fixed_dt = 1.0 / 60.0;
          // Capture settled white-left glass-only background for same-pixel CR reference
          tr[8] = 1.0; tr[9] = 1.0; tr[10] = 1.0;
          glass_forget();
          gl_present(tr, 3, 0.08, 0.08, 0.08);
          unsigned char *bgx = pixels_of_fb(wt_fb);
          // Start dark-left frame 0, then flip left to white for frames 1..15
          tr[8] = 0.08; tr[9] = 0.08; tr[10] = 0.08;
          glass_forget();
          gl_present(tr, 5, 0.08, 0.08, 0.08);
          tr[8] = 1.0; tr[9] = 1.0; tr[10] = 1.0;
          double min_l = 999.0, min_r = 999.0;
          int max_wd = 0;
          int r38 = fb_h - 1 - 38;
          unsigned char *bg_l = bgx + (r38 * fb_w + 130) * 4;
          unsigned char *bg_r = bgx + (r38 * fb_w + 230) * 4;
          double ybl = wcag_luma_u8(bg_l[0], bg_l[1], bg_l[2]);
          double ybr = wcag_luma_u8(bg_r[0], bg_r[1], bg_r[2]);
          for (int fr = 1; fr <= 15; fr++) {
            gl_present(tr, 5, 0.08, 0.08, 0.08);
            unsigned char *px = pixels_of_fb(wt_fb);
            unsigned char *gl_l = px + (r38 * fb_w + 130) * 4;
            unsigned char *gl_r = px + (r38 * fb_w + 230) * 4;
            int wd = 0;
            for (int c = 0; c < 3; c++) { int d = abs((int)gl_l[c] - (int)gl_r[c]); if (d > wd) wd = d; }
            if (wd > max_wd) max_wd = wd;
            double yil = wcag_luma_u8(gl_l[0], gl_l[1], gl_l[2]);
            double yir = wcag_luma_u8(gl_r[0], gl_r[1], gl_r[2]);
            double cr_l = ((yil > ybl ? yil : ybl) + 0.05) / ((yil > ybl ? ybl : yil) + 0.05);
            double cr_r = ((yir > ybr ? yir : ybr) + 0.05) / ((yir > ybr ? ybr : yir) + 0.05);
            if (cr_l < min_l) min_l = cr_l;
            if (cr_r < min_r) min_r = cr_r;
            CHECK(wd <= 1 && cr_l >= 4.5 && cr_r >= 4.5);
            free(px);
          }
          ad_fixed_dt = prev_dt;
          printf("gles_render: dark adaptive 60Hz transition (15 frames) min_left_cr=%.2f min_right_cr=%.2f max_wd=%d\n",
                 min_l, min_r, max_wd);
          free(bgx);
        }

        // R5-2: p.muted (#A8AAAE) on dark-left/white-right & primary (#EDEDED) on dark-left/pure-red-right
        for (int tc = 0; tc < 2; tc++) {
          double mr[4 * MB_INST];
          rect_at(mr, 0, 0, 216, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(mr + MB_INST, 216, 0, 184, 120, 0, 1.0, tc == 0 ? 1.0 : 0.0, tc == 0 ? 1.0 : 0.0, 0);
          rect_at(mr + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -63 - tc);
          mr[2 * MB_INST + 4] = 18.0; mr[2 * MB_INST + 6] = 1.0; mr[2 * MB_INST + 7] = 1.2;
          mr[2 * MB_INST + 11] = 0x67 / 255.0; mr[2 * MB_INST + 12] = 0.6; mr[2 * MB_INST + 13] = 14.0;
          mr[2 * MB_INST + 14] = -1.0; mr[2 * MB_INST + 15] = 1.0;
          mr[2 * MB_INST + 21] = 20.0; mr[2 * MB_INST + 22] = 0.06; mr[2 * MB_INST + 23] = 0.0;
          rect_at(mr + 3 * MB_INST, 232, 32, 12, 12, 10,
                  tc == 0 ? (0xA8/255.0) : 0.93, tc == 0 ? (0xAA/255.0) : 0.93, tc == 0 ? (0xAE/255.0) : 0.93, 0);
          mr[3 * MB_INST + 4] = 4.0;
          mr[3 * MB_INST + 12] = 0.1; mr[3 * MB_INST + 13] = 0.5; mr[3 * MB_INST + 14] = 0.9; mr[3 * MB_INST + 15] = 0.5;
          mr[3 * MB_INST + 21] = 180.0; mr[3 * MB_INST + 22] = 38.0; mr[3 * MB_INST + 23] = 18.0;
          for (int i = 0; i < 4; i++) { mr[i * MB_INST + 18] = 400.0; mr[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(mr, 3, 0.08, 0.08, 0.08);
          unsigned char *bgx = pixels_of_fb(wt_fb);
          glass_forget();
          gl_present(mr, 4, 0.08, 0.08, 0.08);
          unsigned char *px = pixels_of_fb(wt_fb);
          int r38 = fb_h - 1 - 38;
          unsigned char *gp = bgx + (r38 * fb_w + 238) * 4;
          unsigned char *ip = px + (r38 * fb_w + 238) * 4;
          double gl = wcag_luma_u8(gp[0], gp[1], gp[2]), il = wcag_luma_u8(ip[0], ip[1], ip[2]);
          double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
          printf("gles_render: dark adaptive %s glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 tc == 0 ? "p.muted-white" : "pure-red", gp[0], gp[1], gp[2], ip[0], ip[1], ip[2], cr);
          CHECK(cr >= 4.5);
          free(bgx); free(px);
        }

        // R5-3: High tint alpha 0xA8 and 0xCC wide capsule (white-left + dark-right) -> stays dark glass + light ink, CR >= 4.5
        for (int ti = 0; ti < 2; ti++) {
          double alpha = ti == 0 ? (0xA8 / 255.0) : (0xCC / 255.0);
          double ht[4 * MB_INST];
          rect_at(ht, 0, 0, 216, 120, 0, 1.0, 1.0, 1.0, 0);
          rect_at(ht + MB_INST, 216, 0, 184, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(ht + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -65 - ti);
          ht[2 * MB_INST + 4] = 18.0; ht[2 * MB_INST + 6] = 1.0; ht[2 * MB_INST + 7] = 1.2;
          ht[2 * MB_INST + 11] = alpha; ht[2 * MB_INST + 12] = 0.6; ht[2 * MB_INST + 13] = 14.0;
          ht[2 * MB_INST + 14] = -1.0; ht[2 * MB_INST + 15] = 1.0;
          ht[2 * MB_INST + 21] = 20.0; ht[2 * MB_INST + 22] = 0.06; ht[2 * MB_INST + 23] = 0.0;
          rect_at(ht + 3 * MB_INST, 232, 32, 12, 12, 10, 0.93, 0.93, 0.93, 0);
          ht[3 * MB_INST + 4] = 4.0;
          ht[3 * MB_INST + 12] = 0.1; ht[3 * MB_INST + 13] = 0.5; ht[3 * MB_INST + 14] = 0.9; ht[3 * MB_INST + 15] = 0.5;
          ht[3 * MB_INST + 21] = 180.0; ht[3 * MB_INST + 22] = 38.0; ht[3 * MB_INST + 23] = 18.0;
          for (int i = 0; i < 4; i++) { ht[i * MB_INST + 18] = 400.0; ht[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(ht, 3, 0.08, 0.08, 0.08);
          unsigned char *bgx = pixels_of_fb(wt_fb);
          glass_forget();
          gl_present(ht, 4, 0.08, 0.08, 0.08);
          unsigned char *px = pixels_of_fb(wt_fb);
          int r38 = fb_h - 1 - 38;
          unsigned char *gp = bgx + (r38 * fb_w + 238) * 4;
          unsigned char *ip = px + (r38 * fb_w + 238) * 4;
          double gl = wcag_luma_u8(gp[0], gp[1], gp[2]), il = wcag_luma_u8(ip[0], ip[1], ip[2]);
          double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
          printf("gles_render: dark adaptive high-alpha=0x%02X glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 ti == 0 ? 0xA8 : 0xCC, gp[0], gp[1], gp[2], ip[0], ip[1], ip[2], cr);
          CHECK(il > 0.70 && cr >= 4.5);
          free(bgx); free(px);
        }

        // R5-4: Dark -> White -> Dark 50-frame round-trip cache hit (fixed clear color):
        // returning to cached dark blur slot must re-run fad and restore dark glass (< 70) + white icon (> 200) + settling == 0
        {
          double rt[3 * MB_INST];
          rect_at(rt, 0, 0, 400, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(rt + MB_INST, 150, 20, 100, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -67);
          rt[MB_INST + 4] = 18.0; rt[MB_INST + 6] = 1.0; rt[MB_INST + 7] = 1.2;
          rt[MB_INST + 11] = 0x67 / 255.0; rt[MB_INST + 12] = 0.6; rt[MB_INST + 13] = 14.0;
          rt[MB_INST + 14] = -1.0; rt[MB_INST + 15] = 1.0;
          rt[MB_INST + 21] = 20.0; rt[MB_INST + 22] = 0.06; rt[MB_INST + 23] = 0.0;
          rect_at(rt + 2 * MB_INST, 192, 32, 16, 12, 10, 0.93, 0.93, 0.93, 0);
          rt[2 * MB_INST + 4] = 4.0;
          rt[2 * MB_INST + 12] = 0.1; rt[2 * MB_INST + 13] = 0.5; rt[2 * MB_INST + 14] = 0.9; rt[2 * MB_INST + 15] = 0.5;
          rt[2 * MB_INST + 21] = 200.0; rt[2 * MB_INST + 22] = 38.0; rt[2 * MB_INST + 23] = 18.0;
          for (int i = 0; i < 3; i++) { rt[i * MB_INST + 18] = 400.0; rt[i * MB_INST + 19] = 120.0; }
          double prev_dt = ad_fixed_dt;
          ad_fixed_dt = 1.0 / 60.0;
          glass_forget();
          for (int ph = 0; ph < 3; ph++) {
            double v = (ph == 1) ? 1.0 : 0.08;
            rt[8] = v; rt[9] = v; rt[10] = v;
            for (int f = 0; f < 50; f++) gl_present(rt, 3, 0.08, 0.08, 0.08);
          }
          ad_fixed_dt = prev_dt;
          unsigned char *px = pixels_of_fb(wt_fb);
          int r38 = fb_h - 1 - 38;
          unsigned char *gp = px + (r38 * fb_w + 170) * 4;
          unsigned char *ip = px + (r38 * fb_w + 200) * 4;
          int settling = ad_settling;
          printf("gles_render: dark adaptive 50x3 round-trip cache-hit glass=(%d,%d,%d) icon=(%d,%d,%d) settling=%d\n",
                 gp[0], gp[1], gp[2], ip[0], ip[1], ip[2], settling);
          CHECK(gp[0] < 70 && ip[0] > 200 && settling == 0);
          free(px);
        }

        // R6-1: Same capsule raises tint alpha 0x67 -> 0xA8 under partial dirty (98,16,164,42) across 50 frames:
        // must reuse the same adaptive slot immediately (no duplicate concentric slot, every frame CR >= 4.5)
        {
          double pa[4 * MB_INST];
          rect_at(pa, 0, 0, 216, 120, 0, 1.0, 1.0, 1.0, 0);
          rect_at(pa + MB_INST, 216, 0, 184, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(pa + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -68);
          pa[2 * MB_INST + 4] = 18.0; pa[2 * MB_INST + 6] = 1.0; pa[2 * MB_INST + 7] = 1.2;
          pa[2 * MB_INST + 11] = 0x67 / 255.0; pa[2 * MB_INST + 12] = 0.6; pa[2 * MB_INST + 13] = 14.0;
          pa[2 * MB_INST + 14] = -1.0; pa[2 * MB_INST + 15] = 1.0;
          pa[2 * MB_INST + 21] = 20.0; pa[2 * MB_INST + 22] = 0.06; pa[2 * MB_INST + 23] = 0.0;
          rect_at(pa + 3 * MB_INST, 232, 32, 12, 12, 10, 0.93, 0.93, 0.93, 0);
          pa[3 * MB_INST + 4] = 4.0;
          pa[3 * MB_INST + 12] = 0.1; pa[3 * MB_INST + 13] = 0.5; pa[3 * MB_INST + 14] = 0.9; pa[3 * MB_INST + 15] = 0.5;
          pa[3 * MB_INST + 21] = 180.0; pa[3 * MB_INST + 22] = 38.0; pa[3 * MB_INST + 23] = 18.0;
          for (int i = 0; i < 4; i++) { pa[i * MB_INST + 18] = 400.0; pa[i * MB_INST + 19] = 120.0; }
          // Capture 0xA8 glass background without icon
          pa[2 * MB_INST + 11] = 0xA8 / 255.0;
          glass_forget();
          gl_present(pa, 3, 0.08, 0.08, 0.08);
          unsigned char *bgx = pixels_of_fb(wt_fb);
          // Prime 2 frames at 0x67, then switch to 0xA8 with partial dirty (98,16,164,42) for 50 frames
          pa[2 * MB_INST + 11] = 0x67 / 255.0;
          glass_forget();
          gl_present(pa, 4, 0.08, 0.08, 0.08);
          mb_host_render_dirty(98, 16, 164, 42);
          gl_present(pa, 4, 0.08, 0.08, 0.08);
          pa[2 * MB_INST + 11] = 0xA8 / 255.0;
          int r38 = fb_h - 1 - 38;
          unsigned char *gp = bgx + (r38 * fb_w + 238) * 4;
          double gl = wcag_luma_u8(gp[0], gp[1], gp[2]);
          double min_cr = 999.0;
          for (int f = 0; f < 50; f++) {
            mb_host_render_dirty(98, 16, 164, 42);
            gl_present(pa, 4, 0.08, 0.08, 0.08);
            unsigned char *px = pixels_of_fb(wt_fb);
            unsigned char *ip = px + (r38 * fb_w + 238) * 4;
            double il = wcag_luma_u8(ip[0], ip[1], ip[2]);
            double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
            if (cr < min_cr) min_cr = cr;
            CHECK(il > 0.70 && cr >= 4.5);
            free(px);
          }
          printf("gles_render: dark adaptive 0x67->0xA8 partial-dirty 50f min_cr=%.2f\n", min_cr);
          free(bgx);
        }

        // R6-2: Narrow bright edge (split x=242, capsule 100..260) + p.muted (#A8AAAE) icon at (250,38) -> CR >= 4.5
        {
          double nm[4 * MB_INST];
          rect_at(nm, 0, 0, 242, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(nm + MB_INST, 242, 0, 158, 120, 0, 1.0, 1.0, 1.0, 0);
          rect_at(nm + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -69);
          nm[2 * MB_INST + 4] = 18.0; nm[2 * MB_INST + 6] = 1.0; nm[2 * MB_INST + 7] = 1.2;
          nm[2 * MB_INST + 11] = 0x67 / 255.0; nm[2 * MB_INST + 12] = 0.6; nm[2 * MB_INST + 13] = 14.0;
          nm[2 * MB_INST + 14] = -1.0; nm[2 * MB_INST + 15] = 1.0;
          nm[2 * MB_INST + 21] = 20.0; nm[2 * MB_INST + 22] = 0.06; nm[2 * MB_INST + 23] = 0.0;
          rect_at(nm + 3 * MB_INST, 244, 32, 12, 12, 10, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          nm[3 * MB_INST + 4] = 4.0;
          nm[3 * MB_INST + 12] = 0.1; nm[3 * MB_INST + 13] = 0.5; nm[3 * MB_INST + 14] = 0.9; nm[3 * MB_INST + 15] = 0.5;
          nm[3 * MB_INST + 21] = 180.0; nm[3 * MB_INST + 22] = 38.0; nm[3 * MB_INST + 23] = 18.0;
          for (int i = 0; i < 4; i++) { nm[i * MB_INST + 18] = 400.0; nm[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(nm, 3, 0.08, 0.08, 0.08);
          unsigned char *bgx = pixels_of_fb(wt_fb);
          glass_forget();
          gl_present(nm, 4, 0.08, 0.08, 0.08);
          unsigned char *px = pixels_of_fb(wt_fb);
          int r38 = fb_h - 1 - 38;
          unsigned char *gp = bgx + (r38 * fb_w + 250) * 4;
          unsigned char *ip = px + (r38 * fb_w + 250) * 4;
          double gl = wcag_luma_u8(gp[0], gp[1], gp[2]), il = wcag_luma_u8(ip[0], ip[1], ip[2]);
          double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
          printf("gles_render: dark adaptive narrow-bright p.muted glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 gp[0], gp[1], gp[2], ip[0], ip[1], ip[2], cr);
          CHECK(cr >= 4.5);
          free(bgx); free(px);
        }

        // R7-1: Narrow bright edge (split x=242, capsule 100..260) + short muted word (p.muted #A8AAAE)
        // whose glyphs have word-center sample_off pointing to x=222 (dark side): BOTH ends stay uniform & CR >= 4.5
        {
          double mw[5 * MB_INST];
          rect_at(mw, 0, 0, 242, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(mw + MB_INST, 242, 0, 158, 120, 0, 1.0, 1.0, 1.0, 0);
          rect_at(mw + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -70);
          mw[2 * MB_INST + 4] = 18.0; mw[2 * MB_INST + 6] = 1.0; mw[2 * MB_INST + 7] = 1.2;
          mw[2 * MB_INST + 11] = 0x67 / 255.0; mw[2 * MB_INST + 12] = 0.6; mw[2 * MB_INST + 13] = 14.0;
          mw[2 * MB_INST + 14] = -1.0; mw[2 * MB_INST + 15] = 1.0;
          mw[2 * MB_INST + 21] = 20.0; mw[2 * MB_INST + 22] = 0.06; mw[2 * MB_INST + 23] = 0.0;
          // Left glyph at center (200, 38) with word-center offset +22 -> x=222
          rect_at(mw + 3 * MB_INST, 194, 32, 12, 12, 7, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          mw[3 * MB_INST + 6] = 22.0; mw[3 * MB_INST + 7] = 0.0;
          mw[3 * MB_INST + 12] = 16.0; mw[3 * MB_INST + 13] = 16.0; mw[3 * MB_INST + 14] = 16.0; mw[3 * MB_INST + 15] = 16.0;
          mw[3 * MB_INST + 21] = 180.0; mw[3 * MB_INST + 22] = 38.0; mw[3 * MB_INST + 23] = 18.0;
          // Right glyph at center (251, 38) with word-center offset -29 -> x=222 (strictly in white strip x>242)
          rect_at(mw + 4 * MB_INST, 245, 32, 12, 12, 7, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          mw[4 * MB_INST + 6] = -29.0; mw[4 * MB_INST + 7] = 0.0;
          mw[4 * MB_INST + 12] = 16.0; mw[4 * MB_INST + 13] = 16.0; mw[4 * MB_INST + 14] = 16.0; mw[4 * MB_INST + 15] = 16.0;
          mw[4 * MB_INST + 21] = 180.0; mw[4 * MB_INST + 22] = 38.0; mw[4 * MB_INST + 23] = 18.0;
          for (int i = 0; i < 5; i++) { mw[i * MB_INST + 18] = 400.0; mw[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(mw, 3, 0.08, 0.08, 0.08);
          unsigned char *bgx = pixels_of_fb(wt_fb);
          glass_forget();
          gl_present(mw, 5, 0.08, 0.08, 0.08);
          unsigned char *px = pixels_of_fb(wt_fb);
          int r38 = fb_h - 1 - 38;
          unsigned char *bgl = bgx + (r38 * fb_w + 200) * 4, *bgr = bgx + (r38 * fb_w + 251) * 4;
          unsigned char *fgl = px + (r38 * fb_w + 200) * 4, *fgr = px + (r38 * fb_w + 251) * 4;
          double ll = wcag_luma_u8(bgl[0], bgl[1], bgl[2]), fl = wcag_luma_u8(fgl[0], fgl[1], fgl[2]);
          double lr = wcag_luma_u8(bgr[0], bgr[1], bgr[2]), fr = wcag_luma_u8(fgr[0], fgr[1], fgr[2]);
          double crl = ((fl > ll ? fl : ll) + 0.05) / ((fl > ll ? ll : fl) + 0.05);
          double crr = ((fr > lr ? fr : lr) + 0.05) / ((fr > lr ? lr : fr) + 0.05);
          int wd = 0;
          for (int c = 0; c < 3; c++) { int d = abs((int)fgl[c] - (int)fgr[c]); if (d > wd) wd = d; }
          printf("gles_render: dark adaptive narrow-bright muted-word left_cr=%.2f right_cr=%.2f diff=%d\n", crl, crr, wd);
          CHECK(wd <= 1 && crl >= 4.5 && crr >= 4.5);
          free(bgx); free(px);
        }

        // R8-1: Wide 320pt capsule (40..360) with 16pt white stripe sweeping across icon (238,38) and
        // short muted word (center 212, last glyph 239): every stripe position keeps CR >= 4.5 & word_diff <= 1
        {
          double sw[6 * MB_INST];
          rect_at(sw, 0, 0, 400, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(sw + MB_INST, 224, 0, 16, 120, 0, 1.0, 1.0, 1.0, 0);
          rect_at(sw + 2 * MB_INST, 40, 20, 320, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -71);
          sw[2 * MB_INST + 4] = 18.0; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = 1.2;
          sw[2 * MB_INST + 11] = 0x67 / 255.0; sw[2 * MB_INST + 12] = 0.6; sw[2 * MB_INST + 13] = 14.0;
          sw[2 * MB_INST + 14] = -1.0; sw[2 * MB_INST + 15] = 1.0;
          sw[2 * MB_INST + 21] = 20.0; sw[2 * MB_INST + 22] = 0.06; sw[2 * MB_INST + 23] = 0.0;
          // Muted icon at (238, 38)
          rect_at(sw + 3 * MB_INST, 232, 32, 12, 12, 10, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          sw[3 * MB_INST + 4] = 4.0;
          sw[3 * MB_INST + 12] = 0.1; sw[3 * MB_INST + 13] = 0.5; sw[3 * MB_INST + 14] = 0.9; sw[3 * MB_INST + 15] = 0.5;
          sw[3 * MB_INST + 21] = 200.0; sw[3 * MB_INST + 22] = 38.0; sw[3 * MB_INST + 23] = 18.0;
          // Muted short word glyphs: left (185, 38) and right (239, 38), both with sample_off pointing to word center 212
          rect_at(sw + 4 * MB_INST, 179, 32, 12, 12, 7, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          sw[4 * MB_INST + 6] = 27.0; sw[4 * MB_INST + 7] = 0.0;
          sw[4 * MB_INST + 12] = 16.0; sw[4 * MB_INST + 13] = 16.0; sw[4 * MB_INST + 14] = 16.0; sw[4 * MB_INST + 15] = 16.0;
          sw[4 * MB_INST + 21] = 200.0; sw[4 * MB_INST + 22] = 38.0; sw[4 * MB_INST + 23] = 18.0;
          rect_at(sw + 5 * MB_INST, 233, 32, 12, 12, 7, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          sw[5 * MB_INST + 6] = -27.0; sw[5 * MB_INST + 7] = 0.0;
          sw[5 * MB_INST + 12] = 16.0; sw[5 * MB_INST + 13] = 16.0; sw[5 * MB_INST + 14] = 16.0; sw[5 * MB_INST + 15] = 16.0;
          sw[5 * MB_INST + 21] = 200.0; sw[5 * MB_INST + 22] = 38.0; sw[5 * MB_INST + 23] = 18.0;
          for (int i = 0; i < 6; i++) { sw[i * MB_INST + 18] = 400.0; sw[i * MB_INST + 19] = 120.0; }
          int r38 = fb_h - 1 - 38;
          double min_icr = 999.0, min_wcr = 999.0;
          int max_wd = 0;
          for (int sx = 224; sx <= 240; sx += 4) {
            sw[MB_INST + 0] = (double)sx;
            glass_forget();
            gl_present(sw, 3, 0.08, 0.08, 0.08);
            unsigned char *bgx = pixels_of_fb(wt_fb);
            glass_forget();
            gl_present(sw, 4, 0.08, 0.08, 0.08);
            unsigned char *ipx = pixels_of_fb(wt_fb);
            unsigned char *bg_i = bgx + (r38 * fb_w + 238) * 4, *fg_i = ipx + (r38 * fb_w + 238) * 4;
            double li = wcag_luma_u8(bg_i[0], bg_i[1], bg_i[2]), fi = wcag_luma_u8(fg_i[0], fg_i[1], fg_i[2]);
            double icr = ((fi > li ? fi : li) + 0.05) / ((fi > li ? li : fi) + 0.05);
            if (icr < min_icr) min_icr = icr;
            CHECK(icr >= 4.5);
            free(ipx);
            // Word (draw sw[0..2] + sw[4..5] by copying sw[4..5] into slots 3..4 temporarily via separate array)
            double sww[5 * MB_INST];
            memcpy(sww, sw, 3 * MB_INST * sizeof(double));
            memcpy(sww + 3 * MB_INST, sw + 4 * MB_INST, 2 * MB_INST * sizeof(double));
            glass_forget();
            gl_present(sww, 5, 0.08, 0.08, 0.08);
            unsigned char *wpx = pixels_of_fb(wt_fb);
            unsigned char *bgl = bgx + (r38 * fb_w + 185) * 4, *bgr = bgx + (r38 * fb_w + 239) * 4;
            unsigned char *fgl = wpx + (r38 * fb_w + 185) * 4, *fgr = wpx + (r38 * fb_w + 239) * 4;
            double ll = wcag_luma_u8(bgl[0], bgl[1], bgl[2]), fl = wcag_luma_u8(fgl[0], fgl[1], fgl[2]);
            double lr = wcag_luma_u8(bgr[0], bgr[1], bgr[2]), fr = wcag_luma_u8(fgr[0], fgr[1], fgr[2]);
            double crl = ((fl > ll ? fl : ll) + 0.05) / ((fl > ll ? ll : fl) + 0.05);
            double crr = ((fr > lr ? fr : lr) + 0.05) / ((fr > lr ? lr : fr) + 0.05);
            if (crl < min_wcr) min_wcr = crl;
            if (crr < min_wcr) min_wcr = crr;
            for (int c = 0; c < 3; c++) { int d = abs((int)fgl[c] - (int)fgr[c]); if (d > max_wd) max_wd = d; }
            CHECK(crl >= 4.5 && crr >= 4.5 && max_wd <= 1);
            free(wpx); free(bgx);
          }
          printf("gles_render: dark adaptive 320pt 16pt-stripe sweep min_icon_cr=%.2f min_word_cr=%.2f max_wd=%d\n",
                 min_icr, min_wcr, max_wd);
        }

        // R9-1: Wide 144pt muted 12-char word ("Environments", word center x=208, last glyph x=271 over stripe x=268..284)
        // AND R9-2: Off-center muted icon at (200,28) inside 56pt-tall capsule (y=20..76, center y=48) over bright patch [188,212)x[20,32)
        {
          double ew[5 * MB_INST];
          rect_at(ew, 0, 0, 400, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(ew + MB_INST, 268, 0, 16, 120, 0, 1.0, 1.0, 1.0, 0);
          rect_at(ew + 2 * MB_INST, 40, 20, 320, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -72);
          ew[2 * MB_INST + 4] = 18.0; ew[2 * MB_INST + 6] = 1.0; ew[2 * MB_INST + 7] = 1.2;
          ew[2 * MB_INST + 11] = 0x67 / 255.0; ew[2 * MB_INST + 12] = 0.6; ew[2 * MB_INST + 13] = 14.0;
          ew[2 * MB_INST + 14] = -1.0; ew[2 * MB_INST + 15] = 1.0;
          ew[2 * MB_INST + 21] = 20.0; ew[2 * MB_INST + 22] = 0.06; ew[2 * MB_INST + 23] = 0.0;
          rect_at(ew + 3 * MB_INST, 139, 32, 12, 12, 7, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          ew[3 * MB_INST + 6] = 63.0; ew[3 * MB_INST + 7] = 0.0;
          ew[3 * MB_INST + 12] = 16.0; ew[3 * MB_INST + 13] = 16.0; ew[3 * MB_INST + 14] = 16.0; ew[3 * MB_INST + 15] = 16.0;
          ew[3 * MB_INST + 21] = 200.0; ew[3 * MB_INST + 22] = 38.0; ew[3 * MB_INST + 23] = 18.0;
          rect_at(ew + 4 * MB_INST, 265, 32, 12, 12, 7, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          ew[4 * MB_INST + 6] = -63.0; ew[4 * MB_INST + 7] = 0.0;
          ew[4 * MB_INST + 12] = 16.0; ew[4 * MB_INST + 13] = 16.0; ew[4 * MB_INST + 14] = 16.0; ew[4 * MB_INST + 15] = 16.0;
          ew[4 * MB_INST + 21] = 200.0; ew[4 * MB_INST + 22] = 38.0; ew[4 * MB_INST + 23] = 18.0;
          for (int i = 0; i < 5; i++) { ew[i * MB_INST + 18] = 400.0; ew[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(ew, 3, 0.08, 0.08, 0.08);
          unsigned char *bgx = pixels_of_fb(wt_fb);
          glass_forget();
          gl_present(ew, 5, 0.08, 0.08, 0.08);
          unsigned char *px = pixels_of_fb(wt_fb);
          int r38 = fb_h - 1 - 38;
          unsigned char *bgl = bgx + (r38 * fb_w + 145) * 4, *bgr = bgx + (r38 * fb_w + 271) * 4;
          unsigned char *fgl = px + (r38 * fb_w + 145) * 4, *fgr = px + (r38 * fb_w + 271) * 4;
          double ll = wcag_luma_u8(bgl[0], bgl[1], bgl[2]), fl = wcag_luma_u8(fgl[0], fgl[1], fgl[2]);
          double lr = wcag_luma_u8(bgr[0], bgr[1], bgr[2]), fr = wcag_luma_u8(fgr[0], fgr[1], fgr[2]);
          double crl = ((fl > ll ? fl : ll) + 0.05) / ((fl > ll ? ll : fl) + 0.05);
          double crr = ((fr > lr ? fr : lr) + 0.05) / ((fr > lr ? lr : fr) + 0.05);
          int wd = 0;
          for (int c = 0; c < 3; c++) { int d = abs((int)fgl[c] - (int)fgr[c]); if (d > wd) wd = d; }
          printf("gles_render: dark adaptive 144pt-word left_cr=%.2f right_cr=%.2f diff=%d\n", crl, crr, wd);
          CHECK(wd <= 1 && crl >= 4.5 && crr >= 4.5);
          free(bgx); free(px);

          // R9-2: Off-center icon at (200, 28) in 56pt-tall capsule (y=20..76, center y=48)
          double oc[4 * MB_INST];
          rect_at(oc, 0, 0, 400, 120, 0, 0.08, 0.08, 0.08, 0);
          rect_at(oc + MB_INST, 188, 20, 24, 12, 0, 1.0, 1.0, 1.0, 0);
          rect_at(oc + 2 * MB_INST, 120, 20, 160, 56, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -73);
          oc[2 * MB_INST + 4] = 28.0; oc[2 * MB_INST + 6] = 1.0; oc[2 * MB_INST + 7] = 1.2;
          oc[2 * MB_INST + 11] = 0x67 / 255.0; oc[2 * MB_INST + 12] = 0.6; oc[2 * MB_INST + 13] = 14.0;
          oc[2 * MB_INST + 14] = -1.0; oc[2 * MB_INST + 15] = 1.0;
          oc[2 * MB_INST + 21] = 20.0; oc[2 * MB_INST + 22] = 0.06; oc[2 * MB_INST + 23] = 0.0;
          rect_at(oc + 3 * MB_INST, 194, 22, 12, 12, 10, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          oc[3 * MB_INST + 4] = 4.0;
          oc[3 * MB_INST + 12] = 0.1; oc[3 * MB_INST + 13] = 0.5; oc[3 * MB_INST + 14] = 0.9; oc[3 * MB_INST + 15] = 0.5;
          oc[3 * MB_INST + 21] = 200.0; oc[3 * MB_INST + 22] = 48.0; oc[3 * MB_INST + 23] = 28.0;
          for (int i = 0; i < 4; i++) { oc[i * MB_INST + 18] = 400.0; oc[i * MB_INST + 19] = 120.0; }
          glass_forget();
          gl_present(oc, 3, 0.08, 0.08, 0.08);
          bgx = pixels_of_fb(wt_fb);
          glass_forget();
          gl_present(oc, 4, 0.08, 0.08, 0.08);
          px = pixels_of_fb(wt_fb);
          int r28 = fb_h - 1 - 28;
          unsigned char *gp = bgx + (r28 * fb_w + 200) * 4, *ip = px + (r28 * fb_w + 200) * 4;
          double gl = wcag_luma_u8(gp[0], gp[1], gp[2]), il = wcag_luma_u8(ip[0], ip[1], ip[2]);
          double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
          printf("gles_render: dark adaptive offcenter-56pt icon glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 gp[0], gp[1], gp[2], ip[0], ip[1], ip[2], cr);
          CHECK(cr >= 4.5);
          free(bgx); free(px);
        }

        target_fb = pb_fb; fb_w = fbw_save; fb_h = fbh_save; cur_w = w_save; cur_h = h_save; cur_scale = sc_save;
        glBindFramebuffer(GL_FRAMEBUFFER, target_fb);
        glDeleteFramebuffers(1, &wt_fb);
        glDeleteTextures(1, &wt_tex);
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

  // Verify every program group (MB_PROG_*) and auxiliary program (prog_flat, post, ad_prog) compiles and links cleanly.
  {
    while (glGetError() != GL_NO_ERROR) {
    }
    for (int g = 0; g < MB_PROGS; g++) {
      use_prog(g);
      GLint linked = 0;
      CHECK(progs[g].p != 0);
      glGetProgramiv(progs[g].p, GL_LINK_STATUS, &linked);
      if (linked != GL_TRUE) {
        char log[1024];
        glGetProgramInfoLog(progs[g].p, sizeof log, NULL, log);
        fprintf(stderr, "gles_render: program group %d link failed: %s\n", g, log);
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

  // Perf-37: mixed UI primitives (rect/text/shadow/line/icon) with tid==0 batch into a single instanced draw
  // without redundant glUseProgram switches.
  {
    double batch[12 * MB_INST];
    for (int i = 0; i < 3; i++) {
      double y = 4.0 + i * 22.0;
      // shadow (kind 2)
      rect_at(batch + (i * 4 + 0) * MB_INST, 4, y, 80, 18, 2, 0.0, 0.0, 0.0, 0);
      batch[(i * 4 + 0) * MB_INST + 7] = 2.0;
      batch[(i * 4 + 0) * MB_INST + 11] = 0.2;
      // rect (kind 0, small so bands.h does not split)
      rect_at(batch + (i * 4 + 1) * MB_INST, 4, y, 20, 16, 0, 0.2, 0.4, 0.8, 0);
      // glyph (kind 1)
      rect_at(batch + (i * 4 + 2) * MB_INST, 28, y + 2, 10, 10, 1, 0.1, 0.1, 0.1, 0);
      batch[(i * 4 + 2) * MB_INST + 12] = 16; batch[(i * 4 + 2) * MB_INST + 13] = 16;
      batch[(i * 4 + 2) * MB_INST + 14] = 16; batch[(i * 4 + 2) * MB_INST + 15] = 16;
      // line (kind 10)
      rect_at(batch + (i * 4 + 3) * MB_INST, 44, y + 2, 20, 10, 10, 0.9, 0.2, 0.1, 0);
      batch[(i * 4 + 3) * MB_INST + 4] = 2.0;
      batch[(i * 4 + 3) * MB_INST + 12] = 0.1; batch[(i * 4 + 3) * MB_INST + 13] = 0.5;
      batch[(i * 4 + 3) * MB_INST + 14] = 0.9; batch[(i * 4 + 3) * MB_INST + 15] = 0.5;
    }
    int d0 = instanced_draws, b0 = program_binds;
    gl_present(batch, 12, 1.0, 1.0, 1.0);
    int d_used = instanced_draws - d0, b_used = program_binds - b0;
    printf("gles_render: Perf-37 mixed batch (12 mixed inst): draws=%d prog_binds=%d\n", d_used, b_used);
    CHECK(d_used == 1);
    CHECK(b_used == 1);
  }

  // Perf-37: GLES 3.0 program binary disk cache (miss -> store -> warm hit -> corrupt fallback).
  {
    char cdir[256];
    snprintf(cdir, sizeof cdir, "/tmp/mbui_gl_cache_test_%ld", (long)getpid());
    prog_cache_hits = prog_cache_misses = prog_cache_stores = 0;
    gl_set_prog_cache_dir(cdir);
    // Clean any stale files from previous runs
    char rmcmd[320];
    snprintf(rmcmd, sizeof rmcmd, "rm -rf %s", cdir);
    (void)system(rmcmd);

    GLint nfmt = 0;
    glGetIntegerv(GL_NUM_PROGRAM_BINARY_FORMATS, &nfmt);
    printf("gles_render: program_binary_formats=%d\n", (int)nfmt);

    // Cold pass: reset GL objects (simulating fresh context), compile all programs -> miss + store
    for (int g = 0; g < MB_PROGS; g++) { if (progs[g].p) glDeleteProgram(progs[g].p); progs[g].p = 0; }
    if (prog_flat) { glDeleteProgram(prog_flat); prog_flat = 0; }
    if (post) { glDeleteProgram(post); post = 0; }
    if (ad_prog) { glDeleteProgram(ad_prog); ad_prog = 0; }
    if (vs_main) { glDeleteShader(vs_main); vs_main = 0; }
    if (vs_main_ad) { glDeleteShader(vs_main_ad); vs_main_ad = 0; }
    if (vs_post) { glDeleteShader(vs_post); vs_post = 0; }
    prog_now = 0;
    prog_bin_checked = 0;

    for (int g = 0; g < MB_PROGS; g++) use_prog(g);
    ensure_prog_flat();
    ensure_post();
    ensure_ad_prog();
    int total_progs = MB_PROGS + 3;
    if (nfmt > 0) {
      CHECK(prog_cache_misses == total_progs);
      CHECK(prog_cache_stores == total_progs);
      CHECK(prog_cache_hits == 0);

      // Warm pass: reset GL objects, reload all programs from disk cache -> all hits, zero shader compiles
      for (int g = 0; g < MB_PROGS; g++) { glDeleteProgram(progs[g].p); progs[g].p = 0; }
      glDeleteProgram(prog_flat); prog_flat = 0;
      glDeleteProgram(post); post = 0;
      glDeleteProgram(ad_prog); ad_prog = 0;
      if (vs_main) { glDeleteShader(vs_main); vs_main = 0; }
      if (vs_main_ad) { glDeleteShader(vs_main_ad); vs_main_ad = 0; }
      if (vs_post) { glDeleteShader(vs_post); vs_post = 0; }
      prog_now = 0;
      prog_cache_hits = prog_cache_misses = prog_cache_stores = 0;

      for (int g = 0; g < MB_PROGS; g++) {
        use_prog(g);
        GLint linked = 0;
        glGetProgramiv(progs[g].p, GL_LINK_STATUS, &linked);
        CHECK(linked == GL_TRUE);
      }
      ensure_prog_flat();
      ensure_post();
      ensure_ad_prog();
      CHECK(prog_cache_hits == total_progs);
      CHECK(prog_cache_misses == 0);
      CHECK(vs_main == 0 && vs_main_ad == 0 && vs_post == 0);
      CHECK(glGetError() == GL_NO_ERROR);

      // Corrupt-file fallback: overwrite every .glbin with garbage, verify clean fallback recompile & restore
      char corcmd[400];
      snprintf(corcmd, sizeof corcmd, "for f in %s/*.glbin; do printf 'BADDATA' > \"$f\"; done", cdir);
      (void)system(corcmd);
      for (int g = 0; g < MB_PROGS; g++) { glDeleteProgram(progs[g].p); progs[g].p = 0; }
      glDeleteProgram(prog_flat); prog_flat = 0;
      glDeleteProgram(post); post = 0;
      glDeleteProgram(ad_prog); ad_prog = 0;
      prog_now = 0;
      prog_cache_hits = prog_cache_misses = prog_cache_stores = 0;

      for (int g = 0; g < MB_PROGS; g++) {
        use_prog(g);
        GLint linked = 0;
        glGetProgramiv(progs[g].p, GL_LINK_STATUS, &linked);
        CHECK(linked == GL_TRUE);
      }
      ensure_prog_flat();
      ensure_post();
      ensure_ad_prog();
      CHECK(prog_cache_hits == 0);
      CHECK(prog_cache_misses == total_progs);
      CHECK(prog_cache_stores == total_progs);
      CHECK(glGetError() == GL_NO_ERROR);

      // Verify rendering still works after binary-loaded programs
      double smoke[MB_INST];
      rect_at(smoke, 10, 10, 20, 20, 0, 0.2, 0.7, 0.3, 0);
      gl_present(smoke, 1, 0.0, 0.0, 0.0);
      unsigned char *px = pixels_of_fb(surface);
      unsigned char *p = px + ((fb_h - 1 - 40) * fb_w + 40) * 4;
      CHECK(p[1] > 150 && p[0] < 80);
      free(px);
    }
    gl_set_prog_cache_dir(NULL);
    (void)system(rmcmd);
  }

  // Wave 1: gl_setup() preloads only existing valid .glbin cache hits (zero shader compiles on empty/partial/warm).
  {
    char pdir[256];
    snprintf(pdir, sizeof pdir, "/tmp/mbui_gl_preload_test_%ld", (long)getpid());
    char rmcmd[320];
    snprintf(rmcmd, sizeof rmcmd, "rm -rf %s", pdir);
    (void)system(rmcmd);

    GLint nfmt = 0;
    glGetIntegerv(GL_NUM_PROGRAM_BINARY_FORMATS, &nfmt);
    int total_progs = MB_PROGS + 3;

    // 1) Empty cache dir: gl_setup() compiles nothing, loads nothing, records zero hits and zero misses.
    gl_set_prog_cache_dir(pdir);
    prog_cache_hits = prog_cache_misses = prog_cache_stores = 0;
    gl_setup();
    for (int g = 0; g < MB_PROGS; g++) CHECK(progs[g].p == 0);
    CHECK(prog_flat == 0 && post == 0 && ad_prog == 0);
    CHECK(vs_main == 0 && vs_main_ad == 0 && vs_post == 0);
    CHECK(prog_cache_hits == 0 && prog_cache_misses == 0 && prog_now == 0);

    if (nfmt > 0) {
      // 2) Warm cache dir: populate all MB_PROGS + 3 .glbin files, then verify gl_setup() preloads all of them.
      for (int g = 0; g < MB_PROGS; g++) use_prog(g);
      ensure_prog_flat();
      ensure_post();
      ensure_ad_prog();
      CHECK(prog_cache_stores == total_progs);

      prog_cache_hits = prog_cache_misses = prog_cache_stores = 0;
      gl_setup();
      CHECK(prog_cache_hits == total_progs);
      CHECK(prog_cache_misses == 0);
      CHECK(vs_main == 0 && vs_main_ad == 0 && vs_post == 0);
      CHECK(prog_now == 0);
      for (int g = 0; g < MB_PROGS; g++) {
        GLint linked = 0;
        CHECK(progs[g].p != 0);
        glGetProgramiv(progs[g].p, GL_LINK_STATUS, &linked);
        CHECK(linked == GL_TRUE);
      }
      CHECK(prog_flat != 0 && post != 0 && ad_prog != 0);
      CHECK(glGetError() == GL_NO_ERROR);

      glBindFramebuffer(GL_FRAMEBUFFER, surface);
      double smoke[MB_INST];
      rect_at(smoke, 10, 10, 20, 20, 0, 0.2, 0.7, 0.3, 0);
      gl_present(smoke, 1, 0.0, 0.0, 0.0);
      unsigned char *px = pixels_of_fb(surface);
      unsigned char *p = px + ((fb_h - 1 - 40) * fb_w + 40) * 4;
      CHECK(p[1] > 150 && p[0] < 80);
      free(px);
      CHECK(glGetError() == GL_NO_ERROR);

      // 3) Partial cache dir: keep only MB_PROG_UI and post .glbin files, verify gl_setup() loads only those two
      //    with zero shader compilation, and remaining programs still compile lazily on demand.
      (void)system(rmcmd);
      prog_cache_hits = prog_cache_misses = prog_cache_stores = 0;
      gl_setup();
      use_prog(MB_PROG_UI);
      ensure_post();
      CHECK(prog_cache_stores == 2);

      prog_cache_hits = prog_cache_misses = prog_cache_stores = 0;
      gl_setup();
      CHECK(prog_cache_hits == 2);
      CHECK(prog_cache_misses == 0);
      CHECK(vs_main == 0 && vs_main_ad == 0 && vs_post == 0);
      CHECK(prog_now == 0);
      CHECK(progs[MB_PROG_UI].p != 0 && post != 0);
      CHECK(progs[MB_PROG_UI_AD].p == 0 && progs[MB_PROG_PATH].p == 0 && progs[MB_PROG_PATH_AD].p == 0 &&
            progs[MB_PROG_FROSTED].p == 0 && progs[MB_PROG_LIQUID_MERGED].p == 0 &&
            progs[MB_PROG_LIQUID_SINGLE].p == 0 && progs[MB_PROG_LENS].p == 0 && prog_flat == 0 && ad_prog == 0);

      // Draw a frosted glass scene (small rect so bands.h does not invoke prog_flat):
      // triggers lazy compile for MB_PROG_FROSTED alone (MB_PROG_UI and post are already preloaded).
      glBindFramebuffer(GL_FRAMEBUFFER, surface);
      double fg[2 * MB_INST];
      rect_at(fg, 25, 25, 10, 10, 0, 0.9, 0.1, 0.1, 0);
      rect_at(fg + MB_INST, 20, 20, 40, 30, 5, 1, 1, 1, -2);
      fg[MB_INST + 7] = 4;
      fg[MB_INST + 11] = 0.5;
      gl_present(fg, 2, 0.1, 0.2, 0.3);
      CHECK(progs[MB_PROG_FROSTED].p != 0);
      CHECK(prog_cache_misses == 1 && prog_cache_stores == 1);
      CHECK(progs[MB_PROG_UI_AD].p == 0 && progs[MB_PROG_LIQUID_MERGED].p == 0 && progs[MB_PROG_LIQUID_SINGLE].p == 0 &&
            progs[MB_PROG_LENS].p == 0 && progs[MB_PROG_PATH].p == 0 && progs[MB_PROG_PATH_AD].p == 0 &&
            prog_flat == 0 && ad_prog == 0);
      CHECK(glGetError() == GL_NO_ERROR);
    }

    printf("gles_render: gl_setup cache preload ok (nfmt=%d)\n", (int)nfmt);
    gl_set_prog_cache_dir(NULL);
    (void)system(rmcmd);
  }

  // Programs made ahead: asked for once, after a new context's first frame; what was made is taken where a frame
  // first needs it, nothing compiled then; what was made for a context gone is not handed over.
  {
    char adir[256];
    snprintf(adir, sizeof adir, "/tmp/mbui_gl_ahead_test_%ld", (long)getpid());
    char rmcmd[320];
    snprintf(rmcmd, sizeof rmcmd, "rm -rf %s", adir);
    (void)system(rmcmd);
    gl_set_prog_cache_dir(adir);
    gl_setup();
    ahead_started = 0;
    glBindFramebuffer(GL_FRAMEBUFFER, surface);
    double one[MB_INST];
    rect_at(one, 10, 10, 20, 20, 0, 0.2, 0.7, 0.3, 0);
    gl_present(one, 1, 0.0, 0.0, 0.0);
    CHECK(ahead_started == 1 && ahead_started_gen == ahead_gen);
    gl_present(one, 1, 0.0, 0.0, 0.0);
    CHECK(ahead_started == 1);
    // (the first frame made the plain one, MB_PROG_UI, itself: every other slot made ahead)
    CHECK(gl_progs_ahead(ahead_started_gen) == MB_SLOTS - 1);
    CHECK(progs[MB_PROG_FROSTED].p == 0 && post == 0);
    prog_cache_misses = 0;
    double fg[2 * MB_INST];
    rect_at(fg, 25, 25, 10, 10, 0, 0.9, 0.1, 0.1, 0);
    rect_at(fg + MB_INST, 20, 20, 40, 30, 5, 1, 1, 1, -2);
    fg[MB_INST + 7] = 4;
    fg[MB_INST + 11] = 0.5;
    gl_present(fg, 2, 0.1, 0.2, 0.3);
    CHECK(progs[MB_PROG_FROSTED].p != 0 && post != 0);
    CHECK(prog_cache_misses == 0);
    CHECK(ahead_progs[MB_PROG_FROSTED] == 0 && ahead_progs[MB_SLOT_POST] == 0);
    CHECK(glGetError() == GL_NO_ERROR);
    // (a context made anew: the one before's programs dropped, none made for it handed over)
    unsigned old = ahead_gen;
    gl_setup();
    for (int i = 0; i < MB_SLOTS; i++) CHECK(ahead_progs[i] == 0);
    CHECK(gl_progs_ahead(old) == 0);
    for (int i = 0; i < MB_SLOTS; i++) CHECK(ahead_progs[i] == 0);
    printf("gles_render: programs made ahead ok\n");
    gl_set_prog_cache_dir(NULL);
    (void)system(rmcmd);
  }

  // P0 optics fix numerical smoke vectors:
  // 0: Dark Regular (0x20202067) over #000000 -> (30,30,30)
  // 1: Dark Regular (0x20202067) over #1B1C1F -> (46,47,50)
  // 2: Dark Adaptive (0x20202067, adaptive=1) over #FFFFFF -> (93,93,93)
  // 3: Light Regular (0xFDFCFD67) over #0088FF -> (40,154,255), HSV S >= 0.75
  // 4: Pure Clear (0xFFFFFF00, regMix=0) over (0,255,64) -> (0,255,64)
  {
    struct {
      const char *name;
      double bg_r, bg_g, bg_b;
      double t_r, t_g, t_b, t_a;
      double blur, adaptive;
      int exp_r, exp_g, exp_b, tol;
    } p0_cases[5] = {
      {"dark_black",    0.0, 0.0, 0.0,                   32.0/255.0, 32.0/255.0, 32.0/255.0, 0x67/255.0, 2.0,  0.0,  34,  34,  34, 3},
      {"dark_1b1c1f",   27.0/255.0, 28.0/255.0, 31.0/255.0, 32.0/255.0, 32.0/255.0, 32.0/255.0, 0x67/255.0, 2.0, 0.0,  58,  59,  62, 3},
      {"dark_ad_white", 1.0, 1.0, 1.0,                   32.0/255.0, 32.0/255.0, 32.0/255.0, 0x67/255.0, 2.0, -1.0,  90,  90,  90, 6},
      {"light_blue",    0.0, 136.0/255.0, 1.0,           253.0/255.0, 252.0/255.0, 253.0/255.0, 0x67/255.0, 2.0, 0.0, 88, 205, 255, 4},
      {"pure_clear",    0.0, 1.0, 64.0/255.0,            1.0, 1.0, 1.0, 0.0,                              0.0,  0.0,  0, 255,  64, 1},
    };
    double p0[2 * MB_INST];
    for (int ci = 0; ci < 5; ci++) {
      rect_at(p0, 0, 0, W, H, 0, p0_cases[ci].bg_r, p0_cases[ci].bg_g, p0_cases[ci].bg_b, 0);
      rect_at(p0 + MB_INST, 10, 10, 80, 50, 6, p0_cases[ci].t_r, p0_cases[ci].t_g, p0_cases[ci].t_b, -30 - ci);
      p0[MB_INST + 4] = 12.0;
      p0[MB_INST + 6] = 1.0;
      p0[MB_INST + 7] = p0_cases[ci].blur;
      p0[MB_INST + 11] = p0_cases[ci].t_a;
      p0[MB_INST + 12] = 0.0;
      p0[MB_INST + 13] = 4.0;
      p0[MB_INST + 14] = p0_cases[ci].adaptive;
      p0[MB_INST + 15] = 1.0;
      p0[MB_INST + 21] = 0.0;
      p0[MB_INST + 22] = 0.0;
      p0[MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(p0, 2, p0_cases[ci].bg_r, p0_cases[ci].bg_g, p0_cases[ci].bg_b);
      unsigned char *px = pixels_of_fb(surface);
      unsigned char *c = px + ((fb_h - 1 - 70) * fb_w + 100) * 4;
      printf("gles_render: p0_%s rgb=(%d,%d,%d) exp=(%d,%d,%d)\n",
             p0_cases[ci].name, c[0], c[1], c[2], p0_cases[ci].exp_r, p0_cases[ci].exp_g, p0_cases[ci].exp_b);
      CHECK(abs((int)c[0] - p0_cases[ci].exp_r) <= p0_cases[ci].tol);
      CHECK(abs((int)c[1] - p0_cases[ci].exp_g) <= p0_cases[ci].tol);
      CHECK(abs((int)c[2] - p0_cases[ci].exp_b) <= p0_cases[ci].tol);
      if (ci == 3) {
        double mx = fmax(fmax(c[0], c[1]), c[2]);
        double mn = fmin(fmin(c[0], c[1]), c[2]);
        double hsv_s = mx > 0.0 ? (mx - mn) / mx : 0.0;
        printf("gles_render: p0_light_blue hsv_s=%.3f\n", hsv_s);
        CHECK(hsv_s >= 0.62);
      }
      free(px);
    }
  }

  // Commit 2 V8/V9 2D Multi-Pixel ROI Gates (Slider, Switch ON/OFF, 3x TIR rows, 2x phase-shifted TIR, Light Segmented Prism):
  {
    int saved_fb_w = fb_w, saved_fb_h = fb_h;
    double saved_w = cur_w, saved_h = cur_h, saved_s = cur_scale;
    GLuint saved_surface = surface;
    GLuint saved_target = target_fb;
    int VW = 160, VH = 80;
    GLuint vtex = 0, vfb = 0;
    glGenTextures(1, &vtex);
    glGenFramebuffers(1, &vfb);
    surface = vfb;
    target_fb = vfb;

    #define V_RECT(d, x, y, w, h, k, r, g, b, tid) do { \
      rect_at((d), (x), (y), (w), (h), (k), (r), (g), (b), (tid)); \
      (d)[18] = VW; (d)[19] = VH; \
    } while (0)
    #define V_SETUP(SC) do { \
      fb_w = VW * (SC); fb_h = VH * (SC); cur_w = VW; cur_h = VH; cur_scale = (SC); \
      glDeleteTextures(1, &vtex); glGenTextures(1, &vtex); \
      glBindTexture(GL_TEXTURE_2D, vtex); \
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h); \
      glBindFramebuffer(GL_FRAMEBUFFER, vfb); \
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, vtex, 0); \
      glass_forget(); \
    } while (0)
    #define V_PX(buf, xpx, ypx) ((buf) + ((fb_h - 1 - (ypx)) * fb_w + (xpx)) * 4)

    // --- V8a: Slider Dark & Light @ 3x ---
    V_SETUP(3);
    for (int is_light = 0; is_light <= 1; is_light++) {
      double bg = is_light ? 1.0 : 28.0 / 255.0;
      double bg_b = is_light ? 1.0 : 30.0 / 255.0;
      double sl[4 * MB_INST];
      V_RECT(sl, 0, 0, VW, VH, 0, bg, bg, bg_b, 0);
      V_RECT(sl + MB_INST, 10, 37, 70, 6, 0, 0.0, 136.0 / 255.0, 1.0, 0);
      V_RECT(sl + 2 * MB_INST, 80, 37, 70, 6, 0, 120.0 / 255.0, 120.0 / 255.0, 128.0 / 255.0, 0);
      V_RECT(sl + 3 * MB_INST, 51, 21, 58, 38, 6, 1.0, 1.0, 1.0, -50 - is_light);
      sl[3 * MB_INST + 4] = 19.0; sl[3 * MB_INST + 6] = 1.0; sl[3 * MB_INST + 7] = -16.0;
      sl[3 * MB_INST + 11] = 0.0; sl[3 * MB_INST + 12] = 1.0; sl[3 * MB_INST + 13] = 9.0;
      sl[3 * MB_INST + 15] = 1.0; sl[3 * MB_INST + 21] = 9.0; sl[3 * MB_INST + 22] = 0.0; sl[3 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(sl, 4, bg, bg, bg_b);
      unsigned char *px = pixels_of_fb(vfb);

      double max_bh = 0.0, peak_dx = 0.0, h_55 = 0.0;
      double max_gh = 0.0, grey_peak_dx = 0.0, grey_h55 = 0.0;
      for (int i = 0; i <= 18; i++) {
        int x_l = 51 * 3 + i;
        int cnt = 0;
        for (int ypx = 21 * 3; ypx < 59 * 3; ypx++) {
          unsigned char *c = V_PX(px, x_l, ypx);
          if ((int)c[2] - (int)c[0] > 100) cnt++;
        }
        double hpt = cnt / 3.0;
        double dx_l = (i + 0.5) / 3.0;
        if (hpt > max_bh) { max_bh = hpt; peak_dx = dx_l; }
        if (i == 16) h_55 = hpt;
      }
      // Right grey peak height (mirrored pixel centers x_r = 109*3 - 1 - i)
      unsigned char *bg_ref = V_PX(px, 80 * 3, 25 * 3);
      double ref_y = 0.2126 * bg_ref[0] + 0.7152 * bg_ref[1] + 0.0722 * bg_ref[2];
      for (int i = 0; i <= 18; i++) {
        int x_r = 109 * 3 - 1 - i;
        int cnt = 0;
        for (int ypx = 33 * 3; ypx < 47 * 3; ypx++) {
          unsigned char *c = V_PX(px, x_r, ypx);
          double cy = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
          if (is_light ? (cy < ref_y - 70.0) : (cy > ref_y + 20.0)) cnt++;
        }
        double hpt = cnt / 3.0;
        double dx_r = (i + 0.5) / 3.0;
        if (hpt > max_gh) { max_gh = hpt; grey_peak_dx = dx_r; }
        if (i == 16) grey_h55 = hpt;
      }
      // Center unshifted + zero blue at |dy| >= 14pt
      unsigned char *c_l = V_PX(px, (int)(79.3 * 3), 40 * 3);
      unsigned char *c_r = V_PX(px, (int)(80.7 * 3), 40 * 3);
      unsigned char *c_top = V_PX(px, 60 * 3, 25 * 3);
      unsigned char *c_bot = V_PX(px, 60 * 3, 55 * 3);
      // 5-point 3D thickness profile at x = 80 (dy = 0, 0.67, 2.0, 9.0, 24.0pt from y = 21)
      unsigned char *t0 = V_PX(px, 80 * 3, 21 * 3);
      unsigned char *t1 = V_PX(px, 80 * 3, 21 * 3 + 2);
      unsigned char *t2 = V_PX(px, 80 * 3, 23 * 3);
      unsigned char *t9 = V_PX(px, 80 * 3, 30 * 3);
      unsigned char *t24 = V_PX(px, 80 * 3, 45 * 3);
      double y0 = 0.2126 * t0[0] + 0.7152 * t0[1] + 0.0722 * t0[2];
      double y1 = 0.2126 * t1[0] + 0.7152 * t1[1] + 0.0722 * t1[2];
      double y2 = 0.2126 * t2[0] + 0.7152 * t2[1] + 0.0722 * t2[2];
      double y9 = 0.2126 * t9[0] + 0.7152 * t9[1] + 0.0722 * t9[2];
      double y24 = 0.2126 * t24[0] + 0.7152 * t24[1] + 0.0722 * t24[2];
      printf("gles_render: v8_slider(%s) blue_peak=%.2f@dx=%.2f blue_h55=%.2f grey_peak=%.2f@dx=%.2f grey_h55=%.2f prof5=(%.0f,%.0f,%.0f,%.0f,%.0f)\n",
             is_light ? "light" : "dark", max_bh, peak_dx, h_55, max_gh, grey_peak_dx, grey_h55, y0, y1, y2, y9, y24);
      CHECK(max_bh >= 9.5 && max_bh <= 12.5);
      CHECK(peak_dx >= 0.33 && peak_dx <= 1.50);
      CHECK(h_55 >= 5.6 && h_55 <= 6.4);
      CHECK(max_gh >= 9.5 && max_gh <= 12.5);
      CHECK(grey_peak_dx >= 0.33 && grey_peak_dx <= 1.50);
      CHECK(grey_h55 >= 5.6 && grey_h55 <= 6.4);
      CHECK((int)c_l[2] - (int)c_l[0] > 100 && (int)c_r[2] - (int)c_r[0] < 20);
      CHECK((int)c_top[2] - (int)c_top[0] < 20 && (int)c_bot[2] - (int)c_bot[0] < 20);
      CHECK(y1 > y0 && y2 > y9 && y9 < y24);
      free(px);
    }

    // --- V8a2: Horizontal-stripe vertical monotonicity (zero folding) ---
    {
      double st[42 * MB_INST];
      V_RECT(st, 0, 0, VW, VH, 0, 0.0, 0.0, 0.0, 0);
      for (int i = 0; i < 40; i++) {
        double v = fmin(1.0, fmax(0.0, (i - 12.0) / 16.0));
        V_RECT(st + (i + 1) * MB_INST, 0, 20 + i, VW, 1, 0, 1.0 - v, 0.0, v, 0);
      }
      V_RECT(st + 41 * MB_INST, 51, 21, 58, 38, 6, 1.0, 1.0, 1.0, -52);
      st[41 * MB_INST + 4] = 19.0; st[41 * MB_INST + 6] = 1.0; st[41 * MB_INST + 7] = -16.0;
      st[41 * MB_INST + 11] = 0.0; st[41 * MB_INST + 12] = 1.0; st[41 * MB_INST + 13] = 9.0;
      st[41 * MB_INST + 15] = 1.0; st[41 * MB_INST + 21] = 9.0; st[41 * MB_INST + 22] = 0.0; st[41 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(st, 42, 0.0, 0.0, 0.0);
      unsigned char *px = pixels_of_fb(vfb);
      int xpx = (int)(51.85 * 3);
      int prev = -1000;
      int mono_ok = 1;
      for (int ypx = 36 * 3; ypx <= 44 * 3; ypx++) {
        unsigned char *c = V_PX(px, xpx, ypx);
        int cur = (int)c[2] - (int)c[0];  // B - R: invariant to achromatic specular rim
        if (prev > -999 && cur < prev - 6) mono_ok = 0;
        prev = cur;
      }
      CHECK(mono_ok);
      free(px);
    }

    // --- V8b: 124x48pt dropRole=0 magnifier unaffected + Role 0 real zoom (1.18) contact-edge push ---
    {
      double mg[3 * MB_INST];
      V_RECT(mg, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
      V_RECT(mg + MB_INST, 0, 37, VW, 6, 0, 0.0, 136.0 / 255.0, 1.0, 0);
      V_RECT(mg + 2 * MB_INST, 18, 16, 124, 48, 6, 1.0, 1.0, 1.0, -53);
      mg[2 * MB_INST + 4] = 24.0; mg[2 * MB_INST + 6] = 1.0; mg[2 * MB_INST + 7] = 0.0;
      mg[2 * MB_INST + 11] = 0.0; mg[2 * MB_INST + 12] = 1.0; mg[2 * MB_INST + 13] = 8.0;
      mg[2 * MB_INST + 15] = 1.0; mg[2 * MB_INST + 21] = 3.0; mg[2 * MB_INST + 22] = 0.0; mg[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(mg, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *px = pixels_of_fb(vfb);
      int cnt = 0;
      for (int ypx = 16 * 3; ypx < 64 * 3; ypx++) {
        unsigned char *c = V_PX(px, 19 * 3, ypx);
        if ((int)c[2] - (int)c[0] > 100) cnt++;
      }
      printf("gles_render: v8_magnifier_role0 h(1.0)=%.2f\n", cnt / 3.0);
      CHECK(cnt / 3.0 < 7.0);
      free(px);
    }
    {
      double zm[3 * MB_INST];
      V_RECT(zm, 0, 0, VW, VH, 0, 1.0, 0.0, 0.0, 0);
      V_RECT(zm + MB_INST, 0, 0, 55.2, VH, 0, 0.0, 1.0, 0.0, 0);
      V_RECT(zm + 2 * MB_INST, 51, 21, 58, 38, 6, 1.0, 1.0, 1.0, -59);
      zm[2 * MB_INST + 4] = 19.0; zm[2 * MB_INST + 6] = 1.0; zm[2 * MB_INST + 7] = -0.18;
      zm[2 * MB_INST + 11] = 0.0; zm[2 * MB_INST + 12] = 1.0; zm[2 * MB_INST + 13] = 8.0;
      zm[2 * MB_INST + 15] = 1.0; zm[2 * MB_INST + 21] = 8.0; zm[2 * MB_INST + 22] = 0.0; zm[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(zm, 3, 1.0, 0.0, 0.0);
      unsigned char *px = pixels_of_fb(vfb);
      unsigned char *edge = V_PX(px, 51 * 3, 40 * 3);
      printf("gles_render: v8_role0_zoom118_contact rgb=(%d,%d,%d)\n", edge[0], edge[1], edge[2]);
      CHECK((int)edge[1] > (int)edge[0] + 40);
      free(px);
    }

    // --- V9a: Switch ON @ 3x (core + moat from y_top+2 >= 6.5pt + 3 adjacent TIR rows + neutral outer right tip) ---
    {
      double sw[3 * MB_INST];
      V_RECT(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
      V_RECT(sw + MB_INST, 40, 26, 63, 28, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 0);
      sw[MB_INST + 4] = 14.0;
      V_RECT(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -54);
      sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
      sw[2 * MB_INST + 11] = 0.0; sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0;
      sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0; sw[2 * MB_INST + 22] = 0.0; sw[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *px = pixels_of_fb(vfb);
      unsigned char *r0 = V_PX(px, 80 * 3, 21 * 3 + 0);  // d = 0.167pt
      unsigned char *r1 = V_PX(px, 80 * 3, 21 * 3 + 1);  // d = 0.500pt
      unsigned char *r2 = V_PX(px, 80 * 3, 21 * 3 + 2);  // d = 0.833pt
      int gr0 = (int)r0[1] - (int)r0[0];
      int gr1 = (int)r1[1] - (int)r1[0];
      int gr2 = (int)r2[1] - (int)r2[0];
      int core_px = 0, first_core_y = -1;
      for (int ypx = 21 * 3 + 2; ypx < 59 * 3; ypx++) {
        unsigned char *c = V_PX(px, 80 * 3, ypx);
        if ((int)c[1] - (int)c[0] > 60) {
          if (first_core_y < 0) first_core_y = ypx;
          core_px++;
        }
      }
      double moat_top_pt = first_core_y >= 0 ? (first_core_y - (21 * 3 + 2)) / 3.0 : 0.0;
      unsigned char *tip = V_PX(px, (int)(111.5 * 3), 40 * 3);
      int tip_gr = (int)tip[1] - (int)tip[0];
      printf("gles_render: v9_switch_on_3x tir=(%d,%d,%d) core=%.2f moat_top=%.2f tip_gr=%d\n",
             gr0, gr1, gr2, core_px / 3.0, moat_top_pt, tip_gr);
      CHECK(gr0 < 15 && gr1 > 60 && gr2 < 15);
      CHECK(core_px / 3.0 >= 20.0 && core_px / 3.0 <= 22.5);
      CHECK(moat_top_pt >= 6.5);
      CHECK(tip_gr < 15);
      free(px);
    }

    // --- V9b: Switch OFF @ 3x + right-cap inward horizontal profile ---
    {
      double sw[4 * MB_INST];
      V_RECT(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
      V_RECT(sw + MB_INST, 40, 26, 63, 28, 0, 120.0 / 255.0, 120.0 / 255.0, 128.0 / 255.0, 0);
      sw[MB_INST + 4] = 14.0;
      V_RECT(sw + 2 * MB_INST, 85.0, 26.0, 2.0, 28.0, 0, 0.0, 136.0 / 255.0, 1.0, 0);
      V_RECT(sw + 3 * MB_INST, 30.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -55);
      sw[3 * MB_INST + 4] = 19.2; sw[3 * MB_INST + 6] = 1.0; sw[3 * MB_INST + 7] = -32.0;
      sw[3 * MB_INST + 11] = 0.0; sw[3 * MB_INST + 12] = 1.0; sw[3 * MB_INST + 13] = 9.0;
      sw[3 * MB_INST + 15] = 1.0; sw[3 * MB_INST + 21] = 9.0; sw[3 * MB_INST + 22] = 0.0; sw[3 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(sw, 4, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *px = pixels_of_fb(vfb);
      unsigned char *core_c = V_PX(px, 60 * 3, 40 * 3);
      unsigned char *moat_c = V_PX(px, 60 * 3, 25 * 3);
      unsigned char *h0 = V_PX(px, 60 * 3, 21 * 3);
      unsigned char *rm = V_PX(px, 60 * 3, 21 * 3 + 2);
      unsigned char *rcap = V_PX(px, (int)(88.6 * 3), 40 * 3);
      unsigned char *rtir = V_PX(px, (int)(89.3 * 3), 40 * 3);
      int rcap_br = (int)rcap[2] - (int)rcap[0];
      int rtir_br = (int)rtir[2] - (int)rtir[0];
      printf("gles_render: v9_switch_off_3x core=%d moat=%d rim=%d h0=%d rcap_br=%d rtir_br=%d\n",
             core_c[0], moat_c[0], rm[0], h0[0], rcap_br, rtir_br);
      CHECK(core_c[0] > moat_c[0] + 15 && rm[0] > h0[0]);
      CHECK(rcap_br < 20 && rtir_br > 80);
      free(px);
    }

    // --- V9b2: Switch half-press p = 0.5 / 0.6 / 1.0 pinch displacement on 2D color grid ---
    {
      double ps[3] = { 0.5, 0.6, 1.0 };
      int red_rows[3] = { 0, 0, 0 };
      for (int pi = 0; pi < 3; pi++) {
        double p = ps[pi];
        double sw[3 * MB_INST];
        V_RECT(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
        V_RECT(sw + MB_INST, 40, 20, 80, 7, 0, 1.0, 0.0, 0.0, 0);
        V_RECT(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -60 - pi);
        sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
        sw[2 * MB_INST + 11] = 0.0; sw[2 * MB_INST + 12] = 1.0 * p; sw[2 * MB_INST + 13] = 9.0 * p;
        sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0 * p; sw[2 * MB_INST + 22] = 0.0; sw[2 * MB_INST + 23] = 0.0;
        glass_forget();
        gl_present(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
        unsigned char *px = pixels_of_fb(vfb);
        for (int ypx = 27 * 3; ypx < 38 * 3; ypx++) {
          unsigned char *c = V_PX(px, 80 * 3, ypx);
          if ((int)c[0] - (int)c[2] > 80) red_rows[pi]++;
        }
        free(px);
      }
      printf("gles_render: v9_switch_half_press red_shift_px=(p0.5:%d, p0.6:%d, p1.0:%d)\n",
             red_rows[0], red_rows[1], red_rows[2]);
      CHECK(red_rows[0] >= 4 && red_rows[1] >= red_rows[0] && red_rows[2] > red_rows[1]);
    }

    // --- V9c: Light Segmented Prism @ 3x (top/bot cyan, left/right amber, dark-stroke text ROI chroma-0 invariance) ---
    {
      double sg[4 * MB_INST];
      V_RECT(sg, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 0);
      V_RECT(sg + MB_INST, 60.0, 34.0, 4.0, 12.0, 0, 20.0 / 255.0, 20.0 / 255.0, 20.0 / 255.0, 0);
      V_RECT(sg + 2 * MB_INST, 78.0, 36.0, 22.0, 3.0, 0, 20.0 / 255.0, 20.0 / 255.0, 20.0 / 255.0, 0);
      V_RECT(sg + 3 * MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, -56);
      sg[3 * MB_INST + 4] = 22.5; sg[3 * MB_INST + 6] = 1.0; sg[3 * MB_INST + 7] = -48.0;
      sg[3 * MB_INST + 11] = 0.0; sg[3 * MB_INST + 12] = 1.0; sg[3 * MB_INST + 13] = 9.0;
      sg[3 * MB_INST + 15] = 1.0; sg[3 * MB_INST + 21] = 9.0; sg[3 * MB_INST + 22] = 0.04; sg[3 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(sg, 4, 1.0, 1.0, 1.0);
      unsigned char *px = pixels_of_fb(vfb);
      unsigned char *top = V_PX(px, 80 * 3, (int)(18.4 * 3));
      unsigned char *bot = V_PX(px, 80 * 3, (int)(61.6 * 3));
      unsigned char *lft = V_PX(px, (int)(25.9 * 3), 40 * 3);
      unsigned char *rgt = V_PX(px, (int)(134.1 * 3), 40 * 3);
      printf("gles_render: v9_seg_light top B-R=%d bot B-R=%d lft R-B=%d rgt R-B=%d\n",
             (int)top[2] - (int)top[0], (int)bot[2] - (int)bot[0],
             (int)lft[0] - (int)lft[2], (int)rgt[0] - (int)rgt[2]);
      CHECK((int)top[2] - (int)top[0] >= 10);
      CHECK((int)bot[2] - (int)bot[0] >= 10);
      CHECK((int)lft[0] - (int)lft[2] >= 20);
      CHECK((int)rgt[0] - (int)rgt[2] >= 20);
      sg[3 * MB_INST + 20] = -561;
      sg[3 * MB_INST + 22] = 0.0;
      glass_forget();
      gl_present(sg, 4, 1.0, 1.0, 1.0);
      unsigned char *px0 = pixels_of_fb(vfb);
      int text_max_diff = 0;
      for (int py = 32 * 3; py <= 48 * 3; py++) {
        for (int px_i = 55 * 3; px_i <= 105 * 3; px_i++) {
          unsigned char *a = V_PX(px, px_i, py);
          unsigned char *b = V_PX(px0, px_i, py);
          for (int ch = 0; ch < 3; ch++) {
            int df = abs((int)a[ch] - (int)b[ch]);
            if (df > text_max_diff) text_max_diff = df;
          }
        }
      }
      printf("gles_render: v9_seg_text_roi_diff=%d\n", text_max_diff);
      CHECK(text_max_diff == 0);
      // Role 3 interior 1.00x vertical text scale (12pt = 36px@3x dark stroke, no ~20% compression)
      int seg_stroke_span = 0;
      for (int py = 30 * 3; py <= 50 * 3; py++) {
        unsigned char *sc = V_PX(px, 62 * 3, py);
        double sl = 0.2126 * sc[0] + 0.7152 * sc[1] + 0.0722 * sc[2];
        if (sl < 160.0) seg_stroke_span++;
      }
      // Role 3 track pinch (+3.0pt outer grey track pulled white at y=25.5pt, grey at y=29.0pt)
      double tp[3 * MB_INST];
      V_RECT(tp, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 0);
      V_RECT(tp + MB_INST, 10.0, 24.0, 140.0, 32.0, 0, 190.0 / 255.0, 190.0 / 255.0, 190.0 / 255.0, 0);
      V_RECT(tp + 2 * MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, -5611);
      tp[2 * MB_INST + 4] = 22.5; tp[2 * MB_INST + 6] = 1.0; tp[2 * MB_INST + 7] = -48.0;
      tp[2 * MB_INST + 11] = 0.0; tp[2 * MB_INST + 12] = 1.0; tp[2 * MB_INST + 13] = 9.0;
      tp[2 * MB_INST + 15] = 1.0; tp[2 * MB_INST + 21] = 9.0; tp[2 * MB_INST + 22] = 0.04; tp[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(tp, 3, 1.0, 1.0, 1.0);
      unsigned char *pxt = pixels_of_fb(vfb);
      unsigned char *po = V_PX(pxt, 80 * 3, (int)(25.5 * 3));
      unsigned char *pi = V_PX(pxt, 80 * 3, (int)(29.0 * 3));
      double pinch_out_L = 0.2126 * po[0] + 0.7152 * po[1] + 0.0722 * po[2];
      double pinch_in_L = 0.2126 * pi[0] + 0.7152 * pi[1] + 0.0722 * pi[2];
      printf("gles_render: v9_seg_scale stroke_span=%dpx pinch_out_L=%.1f pinch_in_L=%.1f\n",
             seg_stroke_span, pinch_out_L, pinch_in_L);
      CHECK(seg_stroke_span >= 35 && seg_stroke_span <= 37);
      CHECK(pinch_out_L > 240.0 && pinch_in_L < 215.0);
      free(pxt);
      free(px);
      free(px0);
    }

    // --- V9e: Switch uniform green (48,209,88) center RGB ~(57,218,97) + blue-track swap + OFF r9->r4.5 + 5-level press ---
    {
      double sg[2 * MB_INST];
      V_RECT(sg, 0, 0, VW, VH, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 0);
      V_RECT(sg + MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -562);
      sg[MB_INST + 4] = 19.2; sg[MB_INST + 6] = 1.0; sg[MB_INST + 7] = -32.0;
      sg[MB_INST + 11] = 0.0; sg[MB_INST + 12] = 1.0; sg[MB_INST + 13] = 9.0;
      sg[MB_INST + 15] = 1.0; sg[MB_INST + 21] = 9.0; sg[MB_INST + 22] = 0.0; sg[MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(sg, 2, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0);
      unsigned char *px = pixels_of_fb(vfb);
      unsigned char *c = V_PX(px, (int)lround(82.5 * 3), (int)lround(40.2 * 3));
      printf("gles_render: v9_switch_green_ctr rgb=(%d,%d,%d) exp=(57,218,97)\n", c[0], c[1], c[2]);
      CHECK(abs((int)c[0] - 57) <= 2 && abs((int)c[1] - 218) <= 2 && abs((int)c[2] - 97) <= 2);
      free(px);

      // Blue track swap: first colored caustic pixel turns blue
      double sb[3 * MB_INST];
      V_RECT(sb, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
      V_RECT(sb + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 0.0, 122.0 / 255.0, 1.0, 0);
      sb[MB_INST + 4] = 14.0;
      sb[MB_INST + 36] = 14.0; sb[MB_INST + 37] = 14.0; sb[MB_INST + 38] = 14.0; sb[MB_INST + 39] = 14.0;
      V_RECT(sb + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -5621);
      sb[2 * MB_INST + 4] = 19.2; sb[2 * MB_INST + 6] = 1.0; sb[2 * MB_INST + 7] = -32.0;
      sb[2 * MB_INST + 11] = 0.0; sb[2 * MB_INST + 12] = 1.0; sb[2 * MB_INST + 13] = 9.0;
      sb[2 * MB_INST + 15] = 1.0; sb[2 * MB_INST + 21] = 9.0; sb[2 * MB_INST + 22] = 0.0; sb[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(sb, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *pxb = pixels_of_fb(vfb);
      unsigned char *cb = V_PX(pxb, 80 * 3, 21 * 3 + 1);
      printf("gles_render: v9_switch_blue_caustic rgb=(%d,%d,%d) B-R=%d\n", cb[0], cb[1], cb[2], (int)cb[2] - (int)cb[0]);
      CHECK((int)cb[2] - (int)cb[0] >= 100 && cb[2] > cb[1]);
      free(pxb);

      // OFF fixed press: slot 21 9.0 -> 4.5 narrows neutral moat
      int off_moat[2] = {0, 0};
      double refs[2] = {9.0, 4.5};
      for (int ri = 0; ri < 2; ri++) {
        double so[3 * MB_INST];
        V_RECT(so, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
        V_RECT(so + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 120.0 / 255.0, 120.0 / 255.0, 128.0 / 255.0, 0);
        so[MB_INST + 4] = 14.0;
        so[MB_INST + 36] = 14.0; so[MB_INST + 37] = 14.0; so[MB_INST + 38] = 14.0; so[MB_INST + 39] = 14.0;
        V_RECT(so + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -5622 - ri);
        so[2 * MB_INST + 4] = 19.2; so[2 * MB_INST + 6] = 1.0; so[2 * MB_INST + 7] = -32.0;
        so[2 * MB_INST + 11] = 0.0; so[2 * MB_INST + 12] = 1.0; so[2 * MB_INST + 13] = 9.0;
        so[2 * MB_INST + 15] = 1.0; so[2 * MB_INST + 21] = refs[ri]; so[2 * MB_INST + 22] = 0.0; so[2 * MB_INST + 23] = 0.0;
        glass_forget();
        gl_present(so, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
        unsigned char *pxo = pixels_of_fb(vfb);
        int best = 0, cur = 0;
        for (int py = 21 * 3 + 2; py < 40 * 3; py++) {
          unsigned char *c0 = V_PX(pxo, 80 * 3, py);
          if (c0[0] < 95) { cur++; if (cur > best) best = cur; } else cur = 0;
        }
        off_moat[ri] = best;
        free(pxo);
      }
      printf("gles_render: v9_switch_off_moat r9=%dpx r4.5=%dpx\n", off_moat[0], off_moat[1]);
      CHECK(off_moat[0] > off_moat[1] && off_moat[1] >= 1);

      // Real white-cap + glass 5-level press (0.0, 0.25, 0.5, 0.75, 1.0) monotonic visible delta area vs p=0 rest (synced with liquid_toggle.mbt)
      double ps[5] = {0.0, 0.25, 0.50, 0.75, 1.0};
      int areas[5] = {0, 0, 0, 0, 0};
      unsigned char *px_rest = NULL;
      for (int pi = 0; pi < 5; pi++) {
        double p = ps[pi];
        double sc5[4 * MB_INST];
        V_RECT(sc5, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
        V_RECT(sc5 + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 0);
        sc5[MB_INST + 4] = 14.0;
        sc5[MB_INST + 36] = 14.0; sc5[MB_INST + 37] = 14.0; sc5[MB_INST + 38] = 14.0; sc5[MB_INST + 39] = 14.0;
        double cw = 37.0 * (1.0 + 0.60 * p), ch = 24.0 * (1.0 + 0.60 * p);
        double cx0 = 82.5 - cw * 0.5, cy0 = 40.0 - ch * 0.5;
        double cap_a = 1.0 - 1.8 * p;
        if (cap_a < 0.0) cap_a = 0.0;
        if (cap_a > 1.0) cap_a = 1.0;
        V_RECT(sc5 + 2 * MB_INST, cx0, cy0, cw, ch, 0, 1.0, 1.0, 1.0, 0);
        sc5[2 * MB_INST + 4] = ch * 0.5;
        sc5[2 * MB_INST + 11] = cap_a;
        sc5[2 * MB_INST + 36] = ch * 0.5; sc5[2 * MB_INST + 37] = ch * 0.5;
        sc5[2 * MB_INST + 38] = ch * 0.5; sc5[2 * MB_INST + 39] = ch * 0.5;
        int ninst = 3;
        if (p > 0.001) {
          V_RECT(sc5 + 3 * MB_INST, cx0, cy0, cw, ch, 6, 1.0, 1.0, 1.0, -5625 - pi);
          sc5[3 * MB_INST + 4] = ch * 0.5; sc5[3 * MB_INST + 6] = 1.0; sc5[3 * MB_INST + 7] = -32.0;
          sc5[3 * MB_INST + 11] = 0.0; sc5[3 * MB_INST + 12] = p; sc5[3 * MB_INST + 13] = 9.0 * p;
          sc5[3 * MB_INST + 15] = p; sc5[3 * MB_INST + 21] = 9.0 * p; sc5[3 * MB_INST + 22] = 0.0; sc5[3 * MB_INST + 23] = 0.0;
          ninst = 4;
        }
        glass_forget();
        gl_present(sc5, ninst, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
        unsigned char *px5 = pixels_of_fb(vfb);
        if (pi == 0) {
          px_rest = px5;
          areas[0] = 0;
        } else {
          int cnt = 0;
          for (int py = 21 * 3; py <= 59 * 3; py += 2) {
            for (int px_i = 53 * 3; px_i <= 112 * 3; px_i += 2) {
              unsigned char *c0 = V_PX(px5, px_i, py);
              unsigned char *r0 = V_PX(px_rest, px_i, py);
              int d = abs((int)c0[0] - (int)r0[0]) + abs((int)c0[1] - (int)r0[1]) + abs((int)c0[2] - (int)r0[2]);
              if (d >= 30) cnt++;
            }
          }
          areas[pi] = cnt;
          free(px5);
        }
      }
      free(px_rest);
      printf("gles_render: v9_switch_5press_delta_area=(%d,%d,%d,%d,%d)\n", areas[0], areas[1], areas[2], areas[3], areas[4]);
      CHECK(areas[0] < areas[1] && areas[1] < areas[2] && areas[2] < areas[3] && areas[3] < areas[4]);
    }

    // --- V9f: Role 4 Tab monotonic outer meniscus (no fake badge copy from 6.7pt inward; continuous outer lip refraction) ---
    {
      double tb[4 * MB_INST];
      V_RECT(tb, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
      V_RECT(tb + MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, -563);
      tb[MB_INST + 4] = 22.5; tb[MB_INST + 6] = 1.0; tb[MB_INST + 7] = -64.0;
      tb[MB_INST + 11] = 0.0; tb[MB_INST + 12] = 1.0; tb[MB_INST + 13] = 9.0;
      tb[MB_INST + 15] = 1.0; tb[MB_INST + 21] = 9.0; tb[MB_INST + 22] = 0.0; tb[MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(tb, 2, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *px_empty = pixels_of_fb(vfb);
      // 1) Bright orange badge at x_right-6.7 = 128.3 (inward=6.7pt): must NOT be fake-copied to outer meniscus (400, 120).
      V_RECT(tb + MB_INST, 127.3, 35.0, 2.0, 10.0, 0, 1.0, 0.55, 0.0, 0);
      V_RECT(tb + 2 * MB_INST, 117.0, 56.0, 2.0, 6.0, 0, 1.0, 0.55, 0.0, 0);
      V_RECT(tb + 3 * MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, -564);
      tb[3 * MB_INST + 4] = 22.5; tb[3 * MB_INST + 6] = 1.0; tb[3 * MB_INST + 7] = -64.0;
      tb[3 * MB_INST + 11] = 0.0; tb[3 * MB_INST + 12] = 1.0; tb[3 * MB_INST + 13] = 9.0;
      tb[3 * MB_INST + 15] = 1.0; tb[3 * MB_INST + 21] = 9.0; tb[3 * MB_INST + 22] = 0.0; tb[3 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(tb, 4, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *px_icon = pixels_of_fb(vfb);
      unsigned char *a_mid = V_PX(px_empty, 400, 120);
      unsigned char *b_mid = V_PX(px_icon, 400, 120);
      int ghost_delta = abs((int)b_mid[0] - (int)a_mid[0]) + abs((int)b_mid[1] - (int)a_mid[1]);
      unsigned char *a_out = V_PX(px_empty, (int)lround(123.2 * 3), (int)lround(58.9 * 3));
      unsigned char *b_out = V_PX(px_icon, (int)lround(123.2 * 3), (int)lround(58.9 * 3));
      int out_diff = 0;
      for (int ch = 0; ch < 3; ch++) {
        int df = abs((int)b_out[ch] - (int)a_out[ch]);
        if (df > out_diff) out_diff = df;
      }
      // 2) Bright orange bar at x=132.4..133.4 (1.6..2.6pt inward): monotonic outer lip at inward=0.67pt refracts it to x=134.33pt.
      V_RECT(tb + MB_INST, 132.4, 35.0, 1.0, 10.0, 0, 1.0, 0.55, 0.0, 0);
      V_RECT(tb + 2 * MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, -566);
      tb[2 * MB_INST + 4] = 22.5; tb[2 * MB_INST + 6] = 1.0; tb[2 * MB_INST + 7] = -64.0;
      tb[2 * MB_INST + 11] = 0.0; tb[2 * MB_INST + 12] = 1.0; tb[2 * MB_INST + 13] = 9.0;
      tb[2 * MB_INST + 15] = 1.0; tb[2 * MB_INST + 21] = 9.0; tb[2 * MB_INST + 22] = 0.0; tb[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(tb, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *px_lip = pixels_of_fb(vfb);
      unsigned char *a_lip = V_PX(px_empty, 403, 120);
      unsigned char *c_lip = V_PX(px_lip, 403, 120);
      int lip_delta = abs((int)c_lip[0] - (int)a_lip[0]) + abs((int)c_lip[1] - (int)a_lip[1]);
      printf("gles_render: v9_tab_icon_bevel ghost_delta=%d out_diff=%d lip_delta=%d\n", ghost_delta, out_diff, lip_delta);
      CHECK(ghost_delta == 0 && out_diff == 0 && lip_delta >= 80);
      free(px_empty);
      free(px_icon);
      free(px_lip);
    }

    // --- V9g: Role 4 Tab strictly monotonic (empty vs bar A/B diff across d=0..4.0pt, px_x=96..108) ---
    {
      double tg[3 * MB_INST];
      V_RECT(tg, 0, 0, VW, VH, 0, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0, 0);
      V_RECT(tg + MB_INST, 32.5, 8.25, 95.0, 63.5, 6, 1.0, 1.0, 1.0, -5650);
      tg[MB_INST + 4] = 31.75; tg[MB_INST + 6] = 1.0; tg[MB_INST + 7] = -64.0;
      tg[MB_INST + 11] = 0.0; tg[MB_INST + 12] = 1.0; tg[MB_INST + 13] = 9.0;
      tg[MB_INST + 15] = 1.0; tg[MB_INST + 21] = 9.0; tg[MB_INST + 22] = 0.0; tg[MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(tg, 2, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0);
      unsigned char *pxg_empty = pixels_of_fb(vfb);
      V_RECT(tg + MB_INST, 37.5, 8.0, 1.5, 64.0, 0, 90.0 / 255.0, 90.0 / 255.0, 90.0 / 255.0, 0);
      V_RECT(tg + 2 * MB_INST, 32.5, 8.25, 95.0, 63.5, 6, 1.0, 1.0, 1.0, -565);
      tg[2 * MB_INST + 4] = 31.75; tg[2 * MB_INST + 6] = 1.0; tg[2 * MB_INST + 7] = -64.0;
      tg[2 * MB_INST + 11] = 0.0; tg[2 * MB_INST + 12] = 1.0; tg[2 * MB_INST + 13] = 9.0;
      tg[2 * MB_INST + 15] = 1.0; tg[2 * MB_INST + 21] = 9.0; tg[2 * MB_INST + 22] = 0.0; tg[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(tg, 3, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0);
      unsigned char *pxg_bar = pixels_of_fb(vfb);
      unsigned char *co = V_PX(pxg_bar, 117, 120);
      double l_bar = 0.2126 * co[0] + 0.7152 * co[1] + 0.0722 * co[2];
      double ghost_diff = 0.0;
      double l_clean = 255.0;
      for (int px_x = 96; px_x <= 108; px_x++) {
        unsigned char *ce = V_PX(pxg_empty, px_x, 120);
        unsigned char *cb = V_PX(pxg_bar, px_x, 120);
        double le = 0.2126 * ce[0] + 0.7152 * ce[1] + 0.0722 * ce[2];
        double lb = 0.2126 * cb[0] + 0.7152 * cb[1] + 0.0722 * cb[2];
        double gd = fabs(lb - le);
        if (gd > ghost_diff) ghost_diff = gd;
        if (px_x >= 99 && lb < l_clean) l_clean = lb;
      }
      printf("gles_render: v9_tab_no_ghost bar_L=%.1f ghost_diff=%.1f clean_L=%.1f\n", l_bar, ghost_diff, l_clean);
      CHECK(l_bar < 130.0 && ghost_diff <= 2.0 && l_clean > 220.0);
      free(pxg_empty);
      free(pxg_bar);
    }

    // --- V9-Tab-Dark-Clarity: Dark Mode 50pt bar + 62pt Role 4 droplet (6pt overhang clarity & no dead-black side border) ---
    {
      double td[3 * MB_INST];
      V_RECT(td, 0, 0, VW, VH, 0, 25.0 / 255.0, 27.0 / 255.0, 30.0 / 255.0, 0);
      V_RECT(td + MB_INST, 10, 15, 140, 50, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, -567);
      td[MB_INST + 4] = 25.0; td[MB_INST + 6] = 1.0; td[MB_INST + 7] = 0.0;
      td[MB_INST + 11] = 0x67 / 255.0; td[MB_INST + 12] = 0.6; td[MB_INST + 13] = 14.0;
      td[MB_INST + 15] = 1.0; td[MB_INST + 21] = 20.0; td[MB_INST + 22] = 0.0; td[MB_INST + 23] = 0.0;
      V_RECT(td + 2 * MB_INST, 35, 9, 90, 62, 6, 1.0, 1.0, 1.0, -568);
      td[2 * MB_INST + 4] = 31.0; td[2 * MB_INST + 6] = 1.0; td[2 * MB_INST + 7] = -64.0;
      td[2 * MB_INST + 11] = 0.0; td[2 * MB_INST + 12] = 1.0; td[2 * MB_INST + 13] = 9.0;
      td[2 * MB_INST + 15] = 1.0; td[2 * MB_INST + 21] = 9.0; td[2 * MB_INST + 22] = 0.0; td[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(td, 3, 25.0 / 255.0, 27.0 / 255.0, 30.0 / 255.0);
      unsigned char *pxd = pixels_of_fb(vfb);
      unsigned char *ct = V_PX(pxd, 240, 36);
      unsigned char *cb = V_PX(pxd, 240, 204);
      unsigned char *cl = V_PX(pxd, 106, 120);
      unsigned char *cr = V_PX(pxd, 373, 120);
      double top_L = 0.2126 * ct[0] + 0.7152 * ct[1] + 0.0722 * ct[2];
      double bot_L = 0.2126 * cb[0] + 0.7152 * cb[1] + 0.0722 * cb[2];
      double left_L = 0.2126 * cl[0] + 0.7152 * cl[1] + 0.0722 * cl[2];
      double right_L = 0.2126 * cr[0] + 0.7152 * cr[1] + 0.0722 * cr[2];
      printf("gles_render: v9_tab_dark_clarity top_L=%.1f bot_L=%.1f left_L=%.1f right_L=%.1f\n", top_L, bot_L, left_L, right_L);
      CHECK(top_L < 55.0 && bot_L < 55.0 && left_L >= 42.0 && right_L >= 42.0);
      free(pxd);
    }

    // --- V9-Tab-Zoom-Edge-Visible: Role 4 with lensZoom=1.16 (-64.16, refr=13.5, chroma=0.04) keeps center 1.16x zoom while exposing bottom bar edge (+25pt) and outer background ---
    {
      double tz[5 * MB_INST];
      // Pass A: no bottom bar edge line, outer blue block below y=66pt, center dark bar at y=48..50pt, slot7=-64.16
      V_RECT(tz, 0, 0, VW, VH, 0, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0, 0);
      V_RECT(tz + MB_INST, 0, 66.0, VW, VH - 66.0, 0, 40.0 / 255.0, 120.0 / 255.0, 240.0 / 255.0, 0);
      V_RECT(tz + 2 * MB_INST, 65.0, 48.0, 30.0, 2.0, 0, 40.0 / 255.0, 40.0 / 255.0, 40.0 / 255.0, 0);
      V_RECT(tz + 3 * MB_INST, 35.0, 9.0, 90.0, 62.0, 6, 1.0, 1.0, 1.0, -569);
      tz[3 * MB_INST + 4] = 31.0; tz[3 * MB_INST + 6] = 1.0; tz[3 * MB_INST + 7] = -64.16;
      tz[3 * MB_INST + 11] = 0.0; tz[3 * MB_INST + 12] = 1.0; tz[3 * MB_INST + 13] = 13.5;
      tz[3 * MB_INST + 15] = 1.0; tz[3 * MB_INST + 21] = 13.5; tz[3 * MB_INST + 22] = 0.04; tz[3 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(tz, 4, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0);
      unsigned char *pxz_noedge = pixels_of_fb(vfb);
      // Pass B: add dark bottom bar edge line at y=64.5..66.0 (around cy+25pt=65pt)
      V_RECT(tz + 3 * MB_INST, 10.0, 64.5, 140.0, 1.5, 0, 35.0 / 255.0, 35.0 / 255.0, 35.0 / 255.0, 0);
      V_RECT(tz + 4 * MB_INST, 35.0, 9.0, 90.0, 62.0, 6, 1.0, 1.0, 1.0, -570);
      tz[4 * MB_INST + 4] = 31.0; tz[4 * MB_INST + 6] = 1.0; tz[4 * MB_INST + 7] = -64.16;
      tz[4 * MB_INST + 11] = 0.0; tz[4 * MB_INST + 12] = 1.0; tz[4 * MB_INST + 13] = 13.5;
      tz[4 * MB_INST + 15] = 1.0; tz[4 * MB_INST + 21] = 13.5; tz[4 * MB_INST + 22] = 0.04; tz[4 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(tz, 5, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0);
      unsigned char *pxz_edge = pixels_of_fb(vfb);
      // Pass C: same as Pass A but slot7=-64.0 (lensZoom=1.0) to verify center 1.16x magnification
      V_RECT(tz + 3 * MB_INST, 35.0, 9.0, 90.0, 62.0, 6, 1.0, 1.0, 1.0, -571);
      tz[3 * MB_INST + 4] = 31.0; tz[3 * MB_INST + 6] = 1.0; tz[3 * MB_INST + 7] = -64.0;
      tz[3 * MB_INST + 11] = 0.0; tz[3 * MB_INST + 12] = 1.0; tz[3 * MB_INST + 13] = 13.5;
      tz[3 * MB_INST + 15] = 1.0; tz[3 * MB_INST + 21] = 13.5; tz[3 * MB_INST + 22] = 0.04; tz[3 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(tz, 4, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0);
      unsigned char *pxz_nozoom = pixels_of_fb(vfb);
      double edge_diff = 0.0;
      for (int py = 186; py <= 204; py++) {
        unsigned char *ca = V_PX(pxz_noedge, 240, py);
        unsigned char *cb = V_PX(pxz_edge, 240, py);
        double la = 0.2126 * ca[0] + 0.7152 * ca[1] + 0.0722 * ca[2];
        double lb = 0.2126 * cb[0] + 0.7152 * cb[1] + 0.0722 * cb[2];
        double d = fabs(la - lb);
        if (d > edge_diff) edge_diff = d;
      }
      double outer_br = -255.0;
      for (int py = 201; py <= 209; py++) {
        unsigned char *ca = V_PX(pxz_noedge, 240, py);
        double br = (double)ca[2] - (double)ca[0];
        if (br > outer_br) outer_br = br;
      }
      unsigned char *cz1 = V_PX(pxz_noedge, 240, 153);
      unsigned char *cz0 = V_PX(pxz_nozoom, 240, 153);
      double l_zoom = 0.2126 * cz1[0] + 0.7152 * cz1[1] + 0.0722 * cz1[2];
      double l_nozoom = 0.2126 * cz0[0] + 0.7152 * cz0[1] + 0.0722 * cz0[2];
      double center_zoom_diff = l_nozoom - l_zoom;
      printf("gles_render: v9_tab_zoom_edge_visible edge_diff=%.1f outer_br=%.1f center_zoom_diff=%.1f (L_zoom=%.1f L_nozoom=%.1f)\n",
             edge_diff, outer_br, center_zoom_diff, l_zoom, l_nozoom);
      CHECK(edge_diff >= 40.0 && outer_br >= 60.0 && center_zoom_diff >= 60.0);
      free(pxz_noedge);
      free(pxz_edge);
      free(pxz_nozoom);
    }

    // --- V9a2: Switch ON @ 2x phase-shifted integrated green mass ---
    V_SETUP(2);
    for (int ph = 0; ph < 2; ph++) {
      double yoff = ph * 0.25;
      double sw[3 * MB_INST];
      V_RECT(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
      V_RECT(sw + MB_INST, 40, 26 + yoff, 63, 28, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 0);
      sw[MB_INST + 4] = 14.0;
      V_RECT(sw + 2 * MB_INST, 52.9, 21.0 + yoff, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -57 - ph);
      sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
      sw[2 * MB_INST + 11] = 0.0; sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0;
      sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0; sw[2 * MB_INST + 22] = 0.0; sw[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *px = pixels_of_fb(vfb);
      int gsum = 0;
      for (int dy = 0; dy < 3; dy++) {
        unsigned char *c = V_PX(px, 80 * 2, 21 * 2 + dy);
        int d = (int)c[1] - (int)c[0];
        if (d > 0) gsum += d;
      }
      printf("gles_render: v9_switch_on_2x phase=%d green_mass=%d\n", ph, gsum);
      CHECK(gsum > 40);
      free(px);
    }

    // --- V10: Regular Glass Light Parabolic AA (@2x, R=24pt) ---
    {
      V_SETUP(2);
      double rg[2 * MB_INST];
      V_RECT(rg, 0, 0, VW, VH, 0, 242.0 / 255.0, 240.0 / 255.0, 236.0 / 255.0, 0);
      V_RECT(rg + MB_INST, 20, 10, 120, 60, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -70);
      rg[MB_INST + 4] = 24.0; rg[MB_INST + 6] = 1.0; rg[MB_INST + 7] = 0.0;
      rg[MB_INST + 11] = 0.40; rg[MB_INST + 12] = 0.6; rg[MB_INST + 13] = 14.0;
      rg[MB_INST + 15] = 1.0; rg[MB_INST + 21] = 20.0; rg[MB_INST + 22] = 0.0; rg[MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(rg, 2, 242.0 / 255.0, 240.0 / 255.0, 236.0 / 255.0);
      unsigned char *px = pixels_of_fb(vfb);
      double masses[64];
      int n = 0;
      const double bg_L = 0.2126 * 242.0 + 0.7152 * 240.0 + 0.0722 * 236.0;
      for (int py = 20 + 4; py <= 20 + 44; py++) {
        double mass = 0.0;
        for (int xpx = 140 * 2 - 48; xpx <= 140 * 2 + 2; xpx++) {
          unsigned char *c = V_PX(px, xpx, py);
          double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
          if (L < bg_L) mass += (bg_L - L);
        }
        masses[n++] = mass / 2.0;
      }
      double max_d2 = 0.0;
      for (int i = 1; i < n - 1; i++) {
        double d2 = fabs(masses[i - 1] - 2.0 * masses[i] + masses[i + 1]);
        if (d2 > max_d2) max_d2 = d2;
      }
      double side_lmin = 1e9;
      for (int xpx = 140 * 2 - 8; xpx <= 140 * 2 + 2; xpx++) {
        unsigned char *c = V_PX(px, xpx, 40 * 2);
        double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
        if (L < side_lmin) side_lmin = L;
      }
      unsigned char *lc_outer_top = V_PX(px, 80 * 2, 10 * 2 - 1);
      unsigned char *lc_top = V_PX(px, 80 * 2, 10 * 2);
      unsigned char *lc_mid = V_PX(px, 80 * 2, 40 * 2);
      double light_outer_top_L = 0.2126 * lc_outer_top[0] + 0.7152 * lc_outer_top[1] + 0.0722 * lc_outer_top[2];
      double light_top_L = 0.2126 * lc_top[0] + 0.7152 * lc_top[1] + 0.0722 * lc_top[2];
      double light_mid_L = 0.2126 * lc_mid[0] + 0.7152 * lc_mid[1] + 0.0722 * lc_mid[2];
      printf("gles_render: v10_reg_light_2x max_d2=%.2f side_lmin=%.2f outer_top_L=%.1f top_L=%.1f mid_L=%.1f\n",
             max_d2, side_lmin, light_outer_top_L, light_top_L, light_mid_L);
      CHECK(max_d2 <= 14.0);
      CHECK(side_lmin >= 150.0 && side_lmin <= 176.0);
      CHECK(light_outer_top_L <= light_mid_L - 15.0);
      CHECK(light_top_L >= light_mid_L);
      free(px);
      double rgd[2 * MB_INST];
      V_RECT(rgd, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
      V_RECT(rgd + MB_INST, 20, 10, 120, 60, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, -71);
      rgd[MB_INST + 4] = 24.0; rgd[MB_INST + 6] = 1.0; rgd[MB_INST + 7] = 0.0;
      rgd[MB_INST + 11] = 0x67 / 255.0; rgd[MB_INST + 12] = 0.6; rgd[MB_INST + 13] = 14.0;
      rgd[MB_INST + 15] = 1.0; rgd[MB_INST + 21] = 20.0; rgd[MB_INST + 22] = 0.0; rgd[MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(rgd, 2, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *pxd = pixels_of_fb(vfb);
      unsigned char *dc_mid = V_PX(pxd, 80 * 2, 40 * 2);
      unsigned char *dc_top = V_PX(pxd, 80 * 2, 10 * 2);
      unsigned char *dc_side_in = V_PX(pxd, 140 * 2 - 1, 40 * 2);
      unsigned char *dc_side_out = V_PX(pxd, 140 * 2, 40 * 2);
      double l_mid = 0.2126 * dc_mid[0] + 0.7152 * dc_mid[1] + 0.0722 * dc_mid[2];
      double l_top = 0.2126 * dc_top[0] + 0.7152 * dc_top[1] + 0.0722 * dc_top[2];
      double l_side_in = 0.2126 * dc_side_in[0] + 0.7152 * dc_side_in[1] + 0.0722 * dc_side_in[2];
      double l_side_out = 0.2126 * dc_side_out[0] + 0.7152 * dc_side_out[1] + 0.0722 * dc_side_out[2];
      printf("gles_render: v10_reg_dark_2x top=%.1f mid=%.1f side_in=%.1f side_out=%.1f", l_top, l_mid, l_side_in, l_side_out);
      // Full Dark Regular corner ROI (top column + straight side + 45-deg corner arc RGBA8) FNV-1a hash
      uint64_t dh = 14695981039346656037ULL;
      for (int py = 10 * 2; py <= 10 * 2 + 8; py++) {
        unsigned char *c = V_PX(pxd, 80 * 2, py);
        for (int ch = 0; ch < 4; ch++) { dh ^= c[ch]; dh *= 1099511628211ULL; }
      }
      for (int xpx = 140 * 2 - 8; xpx <= 140 * 2 + 1; xpx++) {
        unsigned char *c = V_PX(pxd, xpx, 40 * 2);
        for (int ch = 0; ch < 4; ch++) { dh ^= c[ch]; dh *= 1099511628211ULL; }
      }
      for (int py = 10 * 2; py <= 10 * 2 + 48; py++) {
        for (int xpx = 140 * 2 - 48; xpx <= 140 * 2 + 2; xpx++) {
          unsigned char *c = V_PX(pxd, xpx, py);
          for (int ch = 0; ch < 4; ch++) { dh ^= c[ch]; dh *= 1099511628211ULL; }
        }
      }
      printf(" roi_fnv1a=0x%016llx\n", (unsigned long long)dh);
      // (the 1-point rim of what is outside it, glass_reflect_cases.h: 61 pixels of this ROI 1 LSB from before)
      CHECK(dh == 0xdea498abbecb4a00ULL);
      CHECK(l_top > l_mid + 20.0);
      CHECK(l_side_out <= 14.0 && l_side_out < l_mid - 40.0);
      CHECK(l_side_in >= l_mid - 6.0);
      free(pxd);
      // V10-Dark-On-Bright: Dark Regular glass on #F2F3F0 bright backdrop has no dead-black contour (>= 120/255) and bright top rim.
      double rgdb[2 * MB_INST];
      V_RECT(rgdb, 0, 0, VW, VH, 0, 242.0 / 255.0, 243.0 / 255.0, 240.0 / 255.0, 0);
      V_RECT(rgdb + MB_INST, 20, 10, 120, 60, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, -72);
      rgdb[MB_INST + 4] = 24.0; rgdb[MB_INST + 6] = 1.0; rgdb[MB_INST + 7] = 0.0;
      rgdb[MB_INST + 11] = 0x67 / 255.0; rgdb[MB_INST + 12] = 0.6; rgdb[MB_INST + 13] = 14.0;
      rgdb[MB_INST + 15] = 1.0; rgdb[MB_INST + 21] = 20.0; rgdb[MB_INST + 22] = 0.0; rgdb[MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(rgdb, 2, 242.0 / 255.0, 243.0 / 255.0, 240.0 / 255.0);
      unsigned char *pxdb = pixels_of_fb(vfb);
      unsigned char *db_mid = V_PX(pxdb, 80 * 2, 40 * 2);
      unsigned char *db_top = V_PX(pxdb, 80 * 2, 10 * 2);
      unsigned char *db_side_out = V_PX(pxdb, 140 * 2, 40 * 2);
      int db_out_min = db_side_out[0] < db_side_out[1] ? db_side_out[0] : db_side_out[1];
      if (db_side_out[2] < db_out_min) db_out_min = db_side_out[2];
      double db_l_mid = 0.2126 * db_mid[0] + 0.7152 * db_mid[1] + 0.0722 * db_mid[2];
      double db_l_top = 0.2126 * db_top[0] + 0.7152 * db_top[1] + 0.0722 * db_top[2];
      printf("gles_render: v10_reg_dark_on_bright_2x out_min=%d top=%.1f mid=%.1f\n", db_out_min, db_l_top, db_l_mid);
      CHECK(db_out_min >= 120);
      CHECK(db_l_top > db_l_mid + 20.0);
      free(pxdb);
      // V12-AntiSmear: Regular Light blur=1.2pt at 3x over 2pt alternating dark/light strokes must preserve contrast
      V_SETUP(3);
      double sm[7 * MB_INST];
      V_RECT(sm, 0, 0, VW, VH, 0, 244.0 / 255.0, 241.0 / 255.0, 234.0 / 255.0, 0);
      for (int si = 0; si < 5; si++) {
        V_RECT(sm + (si + 1) * MB_INST, 20, 30 + si * 4, 120, 2, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
      }
      V_RECT(sm + 6 * MB_INST, 20, 10, 120, 60, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -711);
      sm[6 * MB_INST + 4] = 24.0; sm[6 * MB_INST + 6] = 1.0; sm[6 * MB_INST + 7] = 1.2;
      sm[6 * MB_INST + 11] = 0x67 / 255.0; sm[6 * MB_INST + 12] = 0.6; sm[6 * MB_INST + 13] = 20.0;
      sm[6 * MB_INST + 15] = 1.0; sm[6 * MB_INST + 21] = 28.0; sm[6 * MB_INST + 22] = 0.06; sm[6 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(sm, 7, 244.0 / 255.0, 241.0 / 255.0, 234.0 / 255.0);
      unsigned char *pxs = pixels_of_fb(vfb);
      double sm_min = 1e9, sm_max = -1.0;
      for (int py = 34 * 3; py <= 42 * 3; py++) {
        unsigned char *c = V_PX(pxs, 80 * 3, py);
        double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
        if (L < sm_min) sm_min = L;
        if (L > sm_max) sm_max = L;
      }
      printf("gles_render: v12_reg_antismear_3x min_L=%.1f max_L=%.1f delta=%.1f\n", sm_min, sm_max, sm_max - sm_min);
      CHECK(sm_max - sm_min >= 4.0 && sm_min >= 170.0);
      free(pxs);
      V_SETUP(2);
    }

    // --- V11-AA & V11-Wall: Switch ON (Dark & Light, 3x & 2x, shadow-free) ---
    for (int is_light = 0; is_light <= 1; is_light++) {
      double bg = is_light ? 1.0 : 28.0 / 255.0;
      double bg_b = is_light ? 1.0 : 30.0 / 255.0;
      double tr_r = is_light ? 52.0 / 255.0 : 48.0 / 255.0;
      double tr_g = is_light ? 199.0 / 255.0 : 209.0 / 255.0;
      double tr_b = is_light ? 89.0 / 255.0 : 88.0 / 255.0;
      for (int sc_idx = 0; sc_idx < 2; sc_idx++) {
        int sc = (sc_idx == 0) ? 3 : 2;
        V_SETUP(sc);
        double sw[3 * MB_INST];
        V_RECT(sw, 0, 0, VW, VH, 0, bg, bg, bg_b, 0);
        V_RECT(sw + MB_INST, 18.5, 18.0, 63.0, 28.0, 0, tr_r, tr_g, tr_b, 0);
        sw[MB_INST + 4] = 14.0;
        sw[MB_INST + 36] = 14.0; sw[MB_INST + 37] = 14.0; sw[MB_INST + 38] = 14.0; sw[MB_INST + 39] = 14.0;
        V_RECT(sw + 2 * MB_INST, 31.58, 12.8, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -72 - is_light * 2 - sc_idx);
        sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
        sw[2 * MB_INST + 11] = 0.0; sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0;
        sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0; sw[2 * MB_INST + 22] = 0.0; sw[2 * MB_INST + 23] = 0.0;
        glass_forget();
        gl_present(sw, 3, bg, bg, bg_b);
        unsigned char *px = pixels_of_fb(vfb);
        int y_lo = (int)ceil((32.0 - 0.52 * 19.2) * sc - 0.5);
        int y_hi = (int)floor((32.0 + 0.52 * 19.2) * sc - 0.5);
        int xl0 = (sc == 3) ? 89 : 58, xl1 = (sc == 3) ? 109 : 74;
        int xr0 = (sc == 3) ? 259 : 170, xr1 = (sc == 3) ? 281 : 188;
        double minL[128], minR[128];
        int n = 0;
        for (int py = y_lo; py <= y_hi; py++) {
          double ml = 1e9, mr = 1e9;
          for (int xpx = xl0; xpx <= xl1; xpx++) {
            unsigned char *c = V_PX(px, xpx, py);
            double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
            if (L < ml) ml = L;
          }
          for (int xpx = xr0; xpx <= xr1; xpx++) {
            unsigned char *c = V_PX(px, xpx, py);
            double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
            if (L < mr) mr = L;
          }
          minL[n] = ml; minR[n] = mr; n++;
        }
        double d2L = 0.0, d2R = 0.0;
        for (int i = 1; i < n - 1; i++) {
          double a = fabs(minL[i - 1] - 2.0 * minL[i] + minL[i + 1]);
          double b = fabs(minR[i - 1] - 2.0 * minR[i] + minR[i + 1]);
          if (a > d2L) d2L = a;
          if (b > d2R) d2R = b;
        }
        double lim = (sc == 3) ? (is_light ? 12.0 : 10.0) : (is_light ? 14.0 : 12.0);
        printf("gles_render: v11_aa(%s %dx [%d..%d]) L=%.2f R=%.2f (lim=%.1f)\n",
               is_light ? "light" : "dark", sc, y_lo, y_hi, d2L, d2R, lim);
        CHECK(d2L <= lim && d2R <= lim);
        if (sc == 3) {
          int cy_px = 32 * 3;
          int rx_min = 271;
          double r_minL = 1e9;
          for (int xpx = 268; xpx <= 272; xpx++) {
            unsigned char *c = V_PX(px, xpx, cy_px);
            double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
            if (L < r_minL) { r_minL = L; rx_min = xpx; }
          }
          unsigned char *rc0 = V_PX(px, rx_min, cy_px);
          int r_gr = (int)rc0[1] - (int)rc0[0];
          double l1, l2, l3, l4;
          {
            unsigned char *c1 = V_PX(px, rx_min - 1, cy_px);
            unsigned char *c2 = V_PX(px, rx_min - 2, cy_px);
            unsigned char *c3 = V_PX(px, rx_min - 3, cy_px);
            unsigned char *c4 = V_PX(px, rx_min - 4, cy_px);
            l1 = 0.2126 * c1[0] + 0.7152 * c1[1] + 0.0722 * c1[2];
            l2 = 0.2126 * c2[0] + 0.7152 * c2[1] + 0.0722 * c2[2];
            l3 = 0.2126 * c3[0] + 0.7152 * c3[1] + 0.0722 * c3[2];
            l4 = 0.2126 * c4[0] + 0.7152 * c4[1] + 0.0722 * c4[2];
          }
          int r_mono = (l1 >= r_minL && l2 >= l1 && l3 >= l2 && l4 >= l3);
          int best_gr = -999, best_g = 0;
          for (int xpx = 94; xpx <= 98; xpx++) {
            unsigned char *c = V_PX(px, xpx, cy_px);
            int gr = (int)c[1] - (int)c[0];
            if (gr > best_gr && c[1] >= 125 && c[1] <= 165) { best_gr = gr; best_g = c[1]; }
          }
          printf("gles_render: v11_wall(%s 3x) r_minL=%.1f@x=%d r_gr=%d wall=(%.1f,%.1f,%.1f,%.1f) r_mono=%d l_emerald=(G=%d,G-R=%d)\n",
                 is_light ? "light" : "dark", r_minL, rx_min, r_gr, l1, l2, l3, l4, r_mono, best_g, best_gr);
          if (!is_light) {
            CHECK(r_minL <= 14.0 && r_gr <= 12 && r_mono);
          } else {
            CHECK(r_minL >= 170.0 && r_minL <= 205.0 && r_mono && l4 >= 230.0);
          }
          CHECK(best_gr >= 90 && best_g >= 125 && best_g <= 165);
          {
            double prev_moat = -1.0;
            printf("gles_render: v9_left_horn_3x(%s)", is_light ? "light" : "dark");
            for (int dx = 6; dx <= 20; dx += 2) {
              int pc = (int)lround((31.58 + dx) * 3.0);
              double dyc = sqrt(fmax(19.2 * 19.2 - fmax(19.2 - dx, 0.0) * fmax(19.2 - dx, 0.0), 0.0));
              int y0 = (int)lround((32.0 - dyc + 1.0) * 3.0);
              int y1 = (int)lround(32.0 * 3.0);
              int best = 0, cur = 0;
              for (int py = y0; py < y1; py++) {
                unsigned char *c = V_PX(px, pc, py);
                if ((int)c[1] - (int)c[0] < 26) { cur++; if (cur > best) best = cur; } else cur = 0;
              }
              double mpt = best / 3.0;
              printf(" dx=%d:%.2f", dx, mpt);
              if (dx == 6 || dx == 8) CHECK(mpt == 0.0);
              if (dx == 10) CHECK(mpt >= 1.5 && mpt <= 4.5);
              if (dx >= 12 && prev_moat >= 0.0) CHECK(mpt >= prev_moat - 0.35 && mpt - prev_moat <= 3.5);
              if (dx == 20) CHECK(mpt >= 7.0);
              prev_moat = mpt;
            }
            printf("\n");
          }
        }
        free(px);
      }
    }

    // --- V11-Top: Registered 3x & 2x top-wall at 5.00pt & 5.20pt (Dark & Light) ---
    {
      double offs[2] = { 5.00, 5.20 };
      for (int is_light = 0; is_light <= 1; is_light++) {
        double bg = is_light ? 1.0 : 28.0 / 255.0;
        double bg_b = is_light ? 1.0 : 30.0 / 255.0;
        double tr_r = is_light ? 52.0 / 255.0 : 48.0 / 255.0;
        double tr_g = is_light ? 199.0 / 255.0 : 209.0 / 255.0;
        double tr_b = is_light ? 89.0 / 255.0 : 88.0 / 255.0;
        for (int oi = 0; oi < 2; oi++) {
          double off = offs[oi], th = 38.4 - 2.0 * off;
          for (int sc_idx = 0; sc_idx < 2; sc_idx++) {
            int sc = (sc_idx == 0) ? 3 : 2;
            V_SETUP(sc);
            double sw[3 * MB_INST];
            V_RECT(sw, 0, 0, VW, VH, 0, bg, bg, bg_b, 0);
            V_RECT(sw + MB_INST, 40.0, 21.0 + off, 63.0, th, 0, tr_r, tr_g, tr_b, 0);
            sw[MB_INST + 4] = th * 0.5;
            sw[MB_INST + 36] = th * 0.5; sw[MB_INST + 37] = th * 0.5; sw[MB_INST + 38] = th * 0.5; sw[MB_INST + 39] = th * 0.5;
            V_RECT(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -80 - is_light * 4 - oi * 2 - sc_idx);
            sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
            sw[2 * MB_INST + 11] = 0.0; sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0;
            sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0; sw[2 * MB_INST + 22] = 0.0; sw[2 * MB_INST + 23] = 0.0;
            glass_forget();
            gl_present(sw, 3, bg, bg, bg_b);
            unsigned char *px = pixels_of_fb(vfb);
            unsigned char *r0 = V_PX(px, 80 * sc, 21 * sc + 0);
            unsigned char *r1 = V_PX(px, 80 * sc, 21 * sc + 1);
            unsigned char *r2 = V_PX(px, 80 * sc, 21 * sc + 2);
            int gr0 = (int)r0[1] - (int)r0[0], gr1 = (int)r1[1] - (int)r1[0], gr2 = (int)r2[1] - (int)r2[0];
            double l0 = 0.2126 * r0[0] + 0.7152 * r0[1] + 0.0722 * r0[2];
            double l2 = 0.2126 * r2[0] + 0.7152 * r2[1] + 0.0722 * r2[2];
            printf("gles_render: v11_top(%s %dx @%.2fpt) r0=(G-R=%d,L=%.0f) r1=(G-R=%d) r2=(G-R=%d,L=%.0f)\n",
                   is_light ? "light" : "dark", sc, off, gr0, l0, gr1, gr2, l2);
            if (sc == 3) {
              if (!is_light) {
                CHECK(gr0 < 15 && l0 <= 35.0 && gr1 >= 100 && gr2 < 15 && l2 >= 75.0);
              } else {
                CHECK(gr0 < 15 && l0 >= 180.0 && l0 <= 215.0 && gr1 >= 95 && gr2 < 15 && l2 >= 245.0);
              }
            } else {
              CHECK(gr1 >= 70 && gr2 < 15);
            }
            free(px);
          }
        }
      }
    }

    // --- V9h: Switch ON held glassFrost C0 continuity (0 -> eps, 0.108->0.110 veil, 0.127->0.129 blur, 0.60 frosted) ---
    {
      static const double frosts[8] = { 0.0, 0.0001, 0.00011, 0.108, 0.110, 0.127, 0.129, 0.60 };
      V_SETUP(3);
      unsigned char *px0 = NULL, *px_prev = NULL;
      int max_d_eps = 0, max_d_veil = 0, max_d_blur = 0;
      int c0_r = 0, c0_g = 0, c60_r = 0, c60_g = 0;
      for (int fi = 0; fi < 8; fi++) {
        double fr = frosts[fi];
        double alpha = 0.0, slot7 = -32.0, refr = 9.0;
        if (fr > 0.0001) {
          double a_frac = 0.94 * fr;
          alpha = round(a_frac * 255.0) / 255.0;
          double bl = (a_frac <= 0.12) ? 0.0 : 14.0 * ((a_frac - 0.12) / 0.88) * 0.5;
          slot7 = (bl <= 0.0) ? -32.0 : bl;
          refr = 9.0 * (1.0 - 0.55 * fr);
        }
        double sw[3 * MB_INST];
        V_RECT(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
        V_RECT(sw + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 0);
        sw[MB_INST + 4] = 14.0;
        sw[MB_INST + 36] = 14.0; sw[MB_INST + 37] = 14.0; sw[MB_INST + 38] = 14.0; sw[MB_INST + 39] = 14.0;
        V_RECT(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -90 - fi);
        sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = slot7;
        sw[2 * MB_INST + 11] = alpha; sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0;
        sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = refr;
        glass_forget();
        gl_present(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
        unsigned char *px = pixels_of_fb(vfb);
        if (fi == 0) {
          px0 = px;
          unsigned char *c = V_PX(px, 82 * 3, 40 * 3);
          c0_r = c[0]; c0_g = c[1];
        } else {
          if (fi == 2) {
            for (int py = 21 * 3; py <= 59 * 3; py++) {
              for (int xpx = 53 * 3; xpx <= 112 * 3; xpx++) {
                unsigned char *a = V_PX(px0, xpx, py);
                unsigned char *b = V_PX(px, xpx, py);
                for (int ch = 0; ch < 3; ch++) {
                  int d = abs((int)a[ch] - (int)b[ch]);
                  if (d > max_d_eps) max_d_eps = d;
                }
              }
            }
          } else if (fi == 3 || fi == 5) {
            free(px_prev);
            px_prev = px;
            px = NULL;
          } else if (fi == 4 || fi == 6) {
            int md = 0;
            for (int py = 21 * 3; py <= 59 * 3; py++) {
              for (int xpx = 53 * 3; xpx <= 112 * 3; xpx++) {
                unsigned char *a = V_PX(px_prev, xpx, py);
                unsigned char *b = V_PX(px, xpx, py);
                for (int ch = 0; ch < 3; ch++) {
                  int d = abs((int)a[ch] - (int)b[ch]);
                  if (d > md) md = d;
                }
              }
            }
            if (fi == 4) max_d_veil = md; else max_d_blur = md;
          } else if (fi == 7) {
            unsigned char *c = V_PX(px, 82 * 3, 40 * 3);
            c60_r = c[0]; c60_g = c[1];
          }
          free(px);
        }
      }
      free(px0);
      free(px_prev);
      printf("gles_render: v9_switch_frost_continuity max_d_eps=%d max_d_veil=%d max_d_blur=%d ctr0=(%d,%d) ctr60=(%d,%d)\n",
             max_d_eps, max_d_veil, max_d_blur, c0_r, c0_g, c60_r, c60_g);
      CHECK(max_d_eps <= 2);
      CHECK(max_d_veil <= 10);
      CHECK(max_d_blur <= 10);
      CHECK(c60_r > c0_r + 25 && (c60_g - c60_r) < (c0_g - c0_r) - 20);
    }

    // --- V11-Unified-Panel-Glass: Light/Dark 0x80 overlay chroma, rim, white-backdrop WCAG >= 4.5:1, and 0xFF solid zero leak ---
    {
      V_SETUP(2);
      double pb[2 * MB_INST];
      V_RECT(pb, 0, 0, VW, VH, 0, 211.0 / 255.0, 232.0 / 255.0, 253.0 / 255.0, 0);
      V_RECT(pb + MB_INST, 20.0, 10.0, 120.0, 60.0, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -98);
      pb[MB_INST + 4] = 22.0; pb[MB_INST + 6] = 1.0; pb[MB_INST + 7] = 14.0;
      pb[MB_INST + 11] = 0x80 / 255.0; pb[MB_INST + 12] = 0.6; pb[MB_INST + 13] = 20.0;
      pb[MB_INST + 14] = 0.0; pb[MB_INST + 15] = 1.0; pb[MB_INST + 21] = 16.0; pb[MB_INST + 22] = 0.0;
      glass_forget();
      gl_present(pb, 2, 211.0 / 255.0, 232.0 / 255.0, 253.0 / 255.0);
      unsigned char *px = pixels_of_fb(vfb);
      unsigned char *rim = V_PX(px, 80 * 2, 20);
      unsigned char *mid = V_PX(px, 80 * 2, 68);
      int mid_br = (int)mid[2] - (int)mid[0];
      double rim_L = 0.2126 * rim[0] + 0.7152 * rim[1] + 0.0722 * rim[2];
      double mid_L = 0.2126 * mid[0] + 0.7152 * mid[1] + 0.0722 * mid[2];
      free(px);

      pb[MB_INST + 11] = 1.0;
      pb[MB_INST + 20] = -99;
      glass_forget();
      gl_present(pb, 2, 211.0 / 255.0, 232.0 / 255.0, 253.0 / 255.0);
      px = pixels_of_fb(vfb);
      unsigned char *sr = V_PX(px, 80 * 2, 20);
      unsigned char *sm = V_PX(px, 80 * 2, 68);
      double sr_L = 0.2126 * sr[0] + 0.7152 * sr[1] + 0.0722 * sr[2];
      double sm_L = 0.2126 * sm[0] + 0.7152 * sm[1] + 0.0722 * sm[2];
      free(px);

      // Light density monotonicity: 0x80 and 0xB3 (frost) over 0.72 grey vs 0.60 grey
      V_RECT(pb, 0, 0, VW, VH, 0, 0.60, 0.60, 0.60, 0);
      pb[MB_INST + 11] = 0x80 / 255.0; pb[MB_INST + 20] = -100; pb[MB_INST + 22] = 0.0;
      glass_forget(); gl_present(pb, 2, 0.60, 0.60, 0.60);
      px = pixels_of_fb(vfb);
      unsigned char *m60 = V_PX(px, 80 * 2, 68);
      double l60 = 0.2126 * m60[0] + 0.7152 * m60[1] + 0.0722 * m60[2];
      free(px);
      V_RECT(pb, 0, 0, VW, VH, 0, 0.72, 0.72, 0.72, 0);
      pb[MB_INST + 20] = -101;
      glass_forget(); gl_present(pb, 2, 0.72, 0.72, 0.72);
      px = pixels_of_fb(vfb);
      unsigned char *m72 = V_PX(px, 80 * 2, 68);
      double l72 = 0.2126 * m72[0] + 0.7152 * m72[1] + 0.0722 * m72[2];
      free(px);
      V_RECT(pb, 0, 0, VW, VH, 0, 0.60, 0.60, 0.60, 0);
      pb[MB_INST + 11] = 0xB3 / 255.0; pb[MB_INST + 20] = -105; pb[MB_INST + 22] = 0.0;
      glass_forget(); gl_present(pb, 2, 0.60, 0.60, 0.60);
      px = pixels_of_fb(vfb);
      unsigned char *m60c = V_PX(px, 80 * 2, 68);
      double l60_cd = 0.2126 * m60c[0] + 0.7152 * m60c[1] + 0.0722 * m60c[2];
      free(px);
      V_RECT(pb, 0, 0, VW, VH, 0, 0.72, 0.72, 0.72, 0);
      pb[MB_INST + 20] = -106;
      glass_forget(); gl_present(pb, 2, 0.72, 0.72, 0.72);
      px = pixels_of_fb(vfb);
      unsigned char *m72c = V_PX(px, 80 * 2, 68);
      double l72_cd = 0.2126 * m72c[0] + 0.7152 * m72c[1] + 0.0722 * m72c[2];
      free(px);

      // Dark 0x80 vibrant chroma over (60,120,210), Dark 0xCC calmer chroma, and Dark 0x80 over pure white WCAG >= 4.5:1
      V_RECT(pb, 0, 0, VW, VH, 0, 60.0 / 255.0, 120.0 / 255.0, 210.0 / 255.0, 0);
      pb[MB_INST + 8] = 32.0 / 255.0; pb[MB_INST + 9] = 32.0 / 255.0; pb[MB_INST + 10] = 32.0 / 255.0;
      pb[MB_INST + 11] = 0x80 / 255.0; pb[MB_INST + 20] = -102; pb[MB_INST + 22] = 0.0;
      glass_forget(); gl_present(pb, 2, 60.0 / 255.0, 120.0 / 255.0, 210.0 / 255.0);
      px = pixels_of_fb(vfb);
      unsigned char *da = V_PX(px, 80 * 2, 68);
      int d80_br = (int)da[2] - (int)da[0];
      free(px);
      pb[MB_INST + 11] = 0xCC / 255.0; pb[MB_INST + 20] = -104; pb[MB_INST + 22] = 0.0;
      glass_forget(); gl_present(pb, 2, 60.0 / 255.0, 120.0 / 255.0, 210.0 / 255.0);
      px = pixels_of_fb(vfb);
      unsigned char *dc = V_PX(px, 80 * 2, 68);
      int cc_br = (int)dc[2] - (int)dc[0];
      free(px);
      V_RECT(pb, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 0);
      pb[MB_INST + 11] = 0x80 / 255.0; pb[MB_INST + 20] = -107; pb[MB_INST + 22] = 0.0;
      glass_forget(); gl_present(pb, 2, 1.0, 1.0, 1.0);
      px = pixels_of_fb(vfb);
      unsigned char *dw = V_PX(px, 80 * 2, 68);
      double dark_white_L = 0.2126 * dw[0] + 0.7152 * dw[1] + 0.0722 * dw[2];
      free(px);

      // Regular controls (chroma=0.06 vs 0.0) bit-exact zero-diff gate under Light 0x85/0xAB & Dark 0xAB
      int ctrl_max_diff = 0;
      int ctrl_hash_eq = 1;
      struct { int dark; double alpha; double br, bg, bb; } ctrl_cases[3] = {
        { 0, 0x85 / 255.0, 211.0 / 255.0, 232.0 / 255.0, 253.0 / 255.0 },
        { 0, 0xAB / 255.0, 211.0 / 255.0, 232.0 / 255.0, 253.0 / 255.0 },
        { 1, 0xAB / 255.0,  60.0 / 255.0, 120.0 / 255.0, 210.0 / 255.0 },
      };
      pb[MB_INST + 7] = 2.0; pb[MB_INST + 12] = 0.6; pb[MB_INST + 13] = 14.0; pb[MB_INST + 21] = 20.0;
      for (int ci = 0; ci < 3; ci++) {
        V_RECT(pb, 0, 0, VW, VH, 0, ctrl_cases[ci].br, ctrl_cases[ci].bg, ctrl_cases[ci].bb, 0);
        pb[MB_INST + 8] = ctrl_cases[ci].dark ? 32.0 / 255.0 : 253.0 / 255.0;
        pb[MB_INST + 9] = ctrl_cases[ci].dark ? 32.0 / 255.0 : 252.0 / 255.0;
        pb[MB_INST + 10] = ctrl_cases[ci].dark ? 32.0 / 255.0 : 253.0 / 255.0;
        pb[MB_INST + 11] = ctrl_cases[ci].alpha;
        pb[MB_INST + 20] = -110 - ci * 2; pb[MB_INST + 22] = 0.06;
        glass_forget(); gl_present(pb, 2, ctrl_cases[ci].br, ctrl_cases[ci].bg, ctrl_cases[ci].bb);
        unsigned char *p06 = pixels_of_fb(vfb);
        pb[MB_INST + 20] = -111 - ci * 2; pb[MB_INST + 22] = 0.0;
        glass_forget(); gl_present(pb, 2, ctrl_cases[ci].br, ctrl_cases[ci].bg, ctrl_cases[ci].bb);
        unsigned char *p00 = pixels_of_fb(vfb);
        unsigned long long h06 = 14695981039346656037ULL, h00 = 14695981039346656037ULL;
        for (int ry = 20; ry < 140; ry++) {
          for (int rx = 40; rx < 280; rx++) {
            unsigned char *q06 = V_PX(p06, rx, ry);
            unsigned char *q00 = V_PX(p00, rx, ry);
            for (int c = 0; c < 3; c++) {
              int d = abs((int)q06[c] - (int)q00[c]);
              if (d > ctrl_max_diff) ctrl_max_diff = d;
              h06 = (h06 ^ q06[c]) * 1099511628211ULL;
              h00 = (h00 ^ q00[c]) * 1099511628211ULL;
            }
          }
        }
        if (h06 != h00) ctrl_hash_eq = 0;
        free(p06); free(p00);
      }

      printf("gles_render: v11_unified_panel_glass mid_br=%d rim_L=%.1f mid_L=%.1f solid_dL=%.2f l60=%.1f l72=%.1f b3=%.1f->%.1f d80_br=%d cc_br=%d dark_wt_L=%.1f ctrl_diff=%d ctrl_eq=%d\n",
             mid_br, rim_L, mid_L, fabs(sr_L - sm_L), l60, l72, l60_cd, l72_cd, d80_br, cc_br, dark_white_L, ctrl_max_diff, ctrl_hash_eq);
      CHECK(mid_br >= 24);
      CHECK(rim_L >= mid_L + 4.0);
      CHECK(fabs(sr_L - sm_L) <= 1.0);
      CHECK(l72 >= l60 + 2.0);
      CHECK(l72_cd >= l60_cd + 1.0);
      CHECK(d80_br >= 90 && cc_br < d80_br - 25);
      CHECK(dark_white_L <= 102.0);
      CHECK(ctrl_max_diff == 0 && ctrl_hash_eq == 1);
    }
    // V13-Menu-Morph-DualW: sweep liquid_menu_morph_glass alpha codes (Light 103..147, Dark 103..136, Tinted 180..210)
    {
      float mf[MB_INST];
      float max_step_l = 0.0f, max_step_d = 0.0f, max_step_t = 0.0f;
      float prev_w = -1.0f, w_start = 0.0f, w_end = 0.0f;
      for (int ai = 103; ai <= 147; ai++) {
        memset(mf, 0, sizeof mf);
        mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 120.0f; mf[3] = 60.0f; mf[4] = 24.0f;
        mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f + 2.8f * (float)(ai - 103) / 44.0f;
        mf[8] = 253.0f / 255.0f; mf[9] = 252.0f / 255.0f; mf[10] = 253.0f / 255.0f; mf[11] = (float)ai / 255.0f;
        mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -120.0f; mf[21] = 20.0f;
        Grab g;
        CHECK(grab_of(&g, mf, 0, 1, 1) == 1);
        if (ai == 103) w_start = g.dual_w;
        if (ai == 147) w_end = g.dual_w;
        if (prev_w >= 0.0f) {
          float d = fabsf(g.dual_w - prev_w);
          if (d > max_step_l) max_step_l = d;
        }
        prev_w = g.dual_w;
      }
      prev_w = -1.0f;
      for (int ai = 103; ai <= 136; ai++) {
        memset(mf, 0, sizeof mf);
        mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 120.0f; mf[3] = 60.0f; mf[4] = 24.0f;
        mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f + 2.8f * (float)(ai - 103) / 33.0f;
        mf[8] = 32.0f / 255.0f; mf[9] = 32.0f / 255.0f; mf[10] = 32.0f / 255.0f; mf[11] = (float)ai / 255.0f;
        mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -121.0f; mf[21] = 20.0f;
        Grab g;
        CHECK(grab_of(&g, mf, 0, 1, 1) == 1);
        if (prev_w >= 0.0f) {
          float d = fabsf(g.dual_w - prev_w);
          if (d > max_step_d) max_step_d = d;
        }
        prev_w = g.dual_w;
      }
      prev_w = -1.0f;
      for (int ai = 180; ai <= 210; ai++) {
        memset(mf, 0, sizeof mf);
        mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 120.0f; mf[3] = 60.0f; mf[4] = 24.0f;
        mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f;
        mf[8] = 0.0f; mf[9] = 136.0f / 255.0f; mf[10] = 1.0f; mf[11] = (float)ai / 255.0f;
        mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -122.0f; mf[21] = 20.0f;
        Grab g;
        CHECK(grab_of(&g, mf, 0, 1, 1) == 1);
        if (prev_w >= 0.0f) {
          float d = fabsf(g.dual_w - prev_w);
          if (d > max_step_t) max_step_t = d;
        }
        prev_w = g.dual_w;
      }
      printf("gles_render: v13_menu_morph_dual_w start=%.3f end=%.3f max_step=(L=%.4f,D=%.4f,T=%.4f)\n",
             w_start, w_end, max_step_l, max_step_d, max_step_t);
      CHECK(w_start >= 0.80f && w_start <= 0.88f && w_end == 0.0f);
      CHECK(max_step_l <= 0.06f && max_step_d <= 0.06f && max_step_t <= 0.07f);
      // V13b: height-adaptive dual_w (44pt -> ~0.68, 62pt -> ~0.86), zero-frost sharp path (sg==0, k==1 at 2x),
      // and sp >= 2.4 -> k == 1 guard (non-dual blur=1.2pt at 2x -> k=1, sg>0.3).
      {
        Grab g44, g62, gclr;
        memset(mf, 0, sizeof mf);
        mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 132.0f; mf[3] = 44.0f; mf[4] = 22.0f;
        mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f;
        mf[8] = 32.0f / 255.0f; mf[9] = 32.0f / 255.0f; mf[10] = 32.0f / 255.0f; mf[11] = 0x67 / 255.0f;
        mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -123.0f; mf[21] = 20.0f;
        CHECK(grab_of(&g44, mf, 0, 1, 1) == 1);
        CHECK(g44.dual_scale == 1 && fabsf(g44.dual_w - 0.68f) < 0.01f && g44.k == 1 && g44.sg == 0.0f);
        mf[2] = 292.0f; mf[3] = 62.0f; mf[4] = 31.0f;
        CHECK(grab_of(&g62, mf, 0, 1, 1) == 1);
        CHECK(g62.dual_scale == 1 && fabsf(g62.dual_w - 0.86f) < 0.01f && g62.k == 1 && g62.sg == 0.0f);
        // Clear liquid glass (non-dual, blur auto-promoted to 1.2pt -> sp=2.4px at 2x -> k=1, sg>0.3)
        mf[2] = 100.0f; mf[3] = 44.0f; mf[4] = 22.0f; mf[7] = 0.0f;
        mf[8] = 1.0f; mf[9] = 1.0f; mf[10] = 1.0f; mf[11] = 0x1A / 255.0f;
        CHECK(grab_of(&gclr, mf, 0, 1, 1) == 1);
        CHECK(gclr.dual_scale == 0 && gclr.k == 1 && gclr.sg > 0.3f);
        printf("gles_render: v13_dual_k1 w44=%.3f w62=%.3f clr_k=%d clr_sg=%.2f\n",
               g44.dual_w, g62.dual_w, gclr.k, gclr.sg);
        // V13c: effective-sigma continuity (no 1-frame sharpness pop) across menu morph (legacy + v9 3-anchor) & size sweep (14..20pt) at 2x & 3x.
        double max_morph_dsig = 0.0, min_morph_dsig = 0.0, max_sz_dsig = 0.0;
        double max_v9_dsig = 0.0, min_v9_dsig = 0.0;
        for (int sc_i = 2; sc_i <= 3; sc_i++) {
          V_SETUP(sc_i);
          double prev_se = -1.0;
          for (int si = 0; si <= 240; si++) {
            float t = (float)si / 240.0f;
            memset(mf, 0, sizeof mf);
            mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 120.0f; mf[3] = 60.0f; mf[4] = 24.0f;
            mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f + 2.8f * t;
            mf[8] = 253.0f / 255.0f; mf[9] = 252.0f / 255.0f; mf[10] = 253.0f / 255.0f;
            mf[11] = (103.0f + 44.0f * t) / 255.0f;
            mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -124.0f; mf[21] = 20.0f;
            Grab gm;
            CHECK(grab_of(&gm, mf, 0, 1, 1) == 1);
            double pre = gm.k > 0 ? 0.75 * (1.0 - pow(0.25, (double)gm.k)) / 3.0 + 1.0 / 6.0 : 0.0;
            double sgu = (gm.dual_scale && gm.k > 0) ? (gm.sg > 0.55f ? (double)gm.sg : 0.526) : (gm.sg > 0.3f ? (double)gm.sg : 0.0);
            double se = (double)(1 << gm.k) * sqrt(sgu * sgu + pre);
            if (prev_se >= 0.0) {
              double d = se - prev_se;
              if (fabs(d) > max_morph_dsig) max_morph_dsig = fabs(d);
              if (d < min_morph_dsig) min_morph_dsig = d;
            }
            prev_se = se;
          }
          prev_se = -1.0;
          for (int si = 0; si <= 240; si++) {
            float t = (float)si / 240.0f;
            float u = t <= 0.5f ? t * 2.0f : (t - 0.5f) * 2.0f;
            float mb = t <= 0.5f ? (1.2f + 4.8f * u) : (6.0f + 8.0f * u);
            float ma = t <= 0.5f ? (103.0f + 13.0f * u) / 255.0f : (116.0f + 12.0f * u) / 255.0f;
            memset(mf, 0, sizeof mf);
            mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 44.0f + 207.0f * t; mf[3] = 44.0f + 214.0f * t; mf[4] = 22.0f + 10.0f * t;
            mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = mb;
            mf[8] = 253.0f / 255.0f; mf[9] = 252.0f / 255.0f; mf[10] = 253.0f / 255.0f;
            mf[11] = ma;
            mf[12] = 0.6f; mf[13] = 14.0f + 6.0f * t; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -126.0f; mf[21] = 20.0f - 4.0f * t;
            Grab gm;
            CHECK(grab_of(&gm, mf, 0, 1, 1) == 1);
            double pre = gm.k > 0 ? 0.75 * (1.0 - pow(0.25, (double)gm.k)) / 3.0 + 1.0 / 6.0 : 0.0;
            double sgu = (gm.dual_scale && gm.k > 0) ? (gm.sg > 0.55f ? (double)gm.sg : 0.526) : (gm.sg > 0.3f ? (double)gm.sg : 0.0);
            double se = (double)(1 << gm.k) * sqrt(sgu * sgu + pre);
            if (prev_se >= 0.0) {
              double d = se - prev_se;
              if (fabs(d) > max_v9_dsig) max_v9_dsig = fabs(d);
              if (d < min_v9_dsig) min_v9_dsig = d;
            }
            prev_se = se;
          }
          prev_se = -1.0;
          for (int si = 0; si <= 60; si++) {
            float dim = 14.0f + 6.0f * (float)si / 60.0f;
            memset(mf, 0, sizeof mf);
            mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 120.0f; mf[3] = dim; mf[4] = dim * 0.5f;
            mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f;
            mf[8] = 253.0f / 255.0f; mf[9] = 252.0f / 255.0f; mf[10] = 253.0f / 255.0f; mf[11] = 103.0f / 255.0f;
            mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -125.0f; mf[21] = 20.0f;
            Grab gs;
            CHECK(grab_of(&gs, mf, 0, 1, 1) == 1);
            double pre = gs.k > 0 ? 0.75 * (1.0 - pow(0.25, (double)gs.k)) / 3.0 + 1.0 / 6.0 : 0.0;
            double sgu = (gs.dual_scale && gs.k > 0) ? (gs.sg > 0.55f ? (double)gs.sg : 0.526) : (gs.sg > 0.3f ? (double)gs.sg : 0.0);
            double se = (double)(1 << gs.k) * sqrt(sgu * sgu + pre);
            if (prev_se >= 0.0) {
              double d = fabs(se - prev_se);
              if (d > max_sz_dsig) max_sz_dsig = d;
            }
            prev_se = se;
          }
        }
        V_SETUP(2);
        printf("gles_render: v13c_sigma_cont max_morph_dsig=%.3f min_morph_dsig=%.3f v9_3anchor=(%.3f,%.3f) max_sz_dsig=%.3f\n",
               max_morph_dsig, min_morph_dsig, max_v9_dsig, min_v9_dsig, max_sz_dsig);
        CHECK(min_morph_dsig >= -1e-4);
        CHECK(max_morph_dsig <= 0.30);
        CHECK(min_v9_dsig >= -1e-4);
        CHECK(max_v9_dsig <= 0.45);
        CHECK(max_sz_dsig <= 0.30);
      }
      // V14-Opus-Gates: (1) Tinted capsule dark outer contour <= 14; (2) Light Regular rim on black/mid-grey/cream;
      // (3) Clear pill on pure white has zero inner grey band (min_L >= 254).
      {
        V_SETUP(3);
        // (1) Tinted blue capsule on dark bg: outermost side pixel L <= 14
        double tb[2 * MB_INST];
        V_RECT(tb, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
        V_RECT(tb + MB_INST, 20, 18, 78, 44, 6, 0.0, 122.0 / 255.0, 1.0, -130);
        tb[MB_INST + 4] = 22.0; tb[MB_INST + 6] = 1.0; tb[MB_INST + 7] = 1.2;
        tb[MB_INST + 11] = 0x99 / 255.0; tb[MB_INST + 12] = 0.6; tb[MB_INST + 13] = 14.0;
        tb[MB_INST + 15] = 1.0; tb[MB_INST + 21] = 20.0; tb[MB_INST + 22] = 0.06;
        glass_forget();
        gl_present(tb, 2, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
        unsigned char *pxt = pixels_of_fb(vfb);
        unsigned char *ts = V_PX(pxt, 98 * 3, 40 * 3);
        double tint_side_L = 0.2126 * ts[0] + 0.7152 * ts[1] + 0.0722 * ts[2];
        free(pxt);
        // (2) Light Regular non-adaptive pill on pure black, mid-grey (0.5), and cream:
        double bg_vals[3][3] = { {0.0, 0.0, 0.0}, {0.5, 0.5, 0.5}, {244.0 / 255.0, 241.0 / 255.0, 234.0 / 255.0} };
        double top_d[3] = {0}, top2_d[3] = {0}, top_abs[3] = {0};
        for (int bi = 0; bi < 3; bi++) {
          double lr[2 * MB_INST];
          V_RECT(lr, 0, 0, VW, VH, 0, bg_vals[bi][0], bg_vals[bi][1], bg_vals[bi][2], 0);
          V_RECT(lr + MB_INST, 14, 18, 132, 44, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -131 - bi);
          lr[MB_INST + 4] = 22.0; lr[MB_INST + 6] = 1.0; lr[MB_INST + 7] = 1.2;
          lr[MB_INST + 11] = 0x67 / 255.0; lr[MB_INST + 12] = 0.6; lr[MB_INST + 13] = 14.0;
          lr[MB_INST + 15] = 1.0; lr[MB_INST + 21] = 20.0; lr[MB_INST + 22] = 0.06;
          glass_forget();
          gl_present(lr, 2, bg_vals[bi][0], bg_vals[bi][1], bg_vals[bi][2]);
          unsigned char *pxl = pixels_of_fb(vfb);
          unsigned char *cm = V_PX(pxl, 80 * 3, 40 * 3);
          unsigned char *c0 = V_PX(pxl, 80 * 3, 18 * 3);
          unsigned char *c2 = V_PX(pxl, 80 * 3, 18 * 3 + 2);
          double lm = 0.2126 * cm[0] + 0.7152 * cm[1] + 0.0722 * cm[2];
          double l0 = 0.2126 * c0[0] + 0.7152 * c0[1] + 0.0722 * c0[2];
          double l2 = 0.2126 * c2[0] + 0.7152 * c2[1] + 0.0722 * c2[2];
          top_d[bi] = l0 - lm; top2_d[bi] = l2 - lm; top_abs[bi] = l0;
          free(pxl);
        }
        // (3) Clear pill on pure white: no inner bevel shadow grey band (all interior rows >= 254)
        double cw[2 * MB_INST];
        V_RECT(cw, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 0);
        V_RECT(cw + MB_INST, 20, 18, 100, 44, 6, 1.0, 1.0, 1.0, -135);
        cw[MB_INST + 4] = 22.0; cw[MB_INST + 6] = 1.0; cw[MB_INST + 7] = 0.0;
        cw[MB_INST + 11] = 0x1A / 255.0; cw[MB_INST + 12] = 0.6; cw[MB_INST + 13] = 14.0;
        cw[MB_INST + 15] = 1.0; cw[MB_INST + 21] = 16.0;
        glass_forget();
        gl_present(cw, 2, 1.0, 1.0, 1.0);
        unsigned char *pxc = pixels_of_fb(vfb);
        double clr_min_L = 999.0;
        for (int py = 18 * 3 + 2; py <= 62 * 3 - 2; py++) {
          unsigned char *cp = V_PX(pxc, 70 * 3, py);
          double L = 0.2126 * cp[0] + 0.7152 * cp[1] + 0.0722 * cp[2];
          if (L < clr_min_L) clr_min_L = L;
        }
        free(pxc);
        printf("gles_render: v14_opus_gates tint_side=%.1f blk_d=(+%.1f,+%.1f) mid_d=(+%.1f,+%.1f) crm=%.1f clr_min=%.1f\n",
               tint_side_L, top_d[0], top2_d[0], top_d[1], top2_d[1], top_abs[2], clr_min_L);
        CHECK(tint_side_L <= 14.0);
        CHECK(top_d[0] <= 50.0 && top2_d[0] <= 28.0);
        CHECK(top_d[1] <= 38.0 && top2_d[1] <= 18.0);
        CHECK(top_abs[2] >= 252.0);
        CHECK(clr_min_L >= 254.0);
        // V14b-Scroll-Shimmer: 1px vertical scroll shift-invariance of 44pt Light Regular pill over crisp dark strokes at 2x & 3x.
        for (int sc_i = 2; sc_i <= 3; sc_i++) {
          V_SETUP(sc_i);
          unsigned char *fpx[2] = {NULL, NULL};
          for (int fi = 0; fi < 2; fi++) {
            double dy = (double)fi / (double)sc_i;
            double sb[7 * MB_INST];
            V_RECT(sb, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 0);
            V_RECT(sb + 1 * MB_INST, 0, 24.0 + dy, VW, 1.0, 0, 0.08, 0.08, 0.08, 0);
            V_RECT(sb + 2 * MB_INST, 0, 31.0 + dy, VW, 1.5, 0, 0.08, 0.08, 0.08, 0);
            V_RECT(sb + 3 * MB_INST, 0, 39.0 + dy, VW, 2.0, 0, 0.08, 0.08, 0.08, 0);
            V_RECT(sb + 4 * MB_INST, 0, 47.0 + dy, VW, 1.0, 0, 0.08, 0.08, 0.08, 0);
            V_RECT(sb + 5 * MB_INST, 0, 54.0 + dy, VW, 2.0, 0, 0.08, 0.08, 0.08, 0);
            V_RECT(sb + 6 * MB_INST, 14, 18, 132, 44, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -140 - sc_i * 2 - fi);
            sb[6 * MB_INST + 4] = 22.0; sb[6 * MB_INST + 6] = 1.0; sb[6 * MB_INST + 7] = 1.2;
            sb[6 * MB_INST + 11] = 0x67 / 255.0; sb[6 * MB_INST + 12] = 0.6; sb[6 * MB_INST + 13] = 14.0;
            sb[6 * MB_INST + 15] = 1.0; sb[6 * MB_INST + 21] = 20.0; sb[6 * MB_INST + 22] = 0.06;
            glass_forget();
            gl_present(sb, 7, 1.0, 1.0, 1.0);
            fpx[fi] = pixels_of_fb(vfb);
          }
          double max_d_flat = 0.0, sum2_flat = 0.0;
          int cnt_flat = 0;
          for (int py = 28 * sc_i; py < 52 * sc_i - 1; py++) {
            for (int px = 44 * sc_i; px < 116 * sc_i; px++) {
              unsigned char *p0 = V_PX(fpx[0], px, py);
              unsigned char *p1 = V_PX(fpx[1], px, py + 1);
              double l0 = 0.2126 * p0[0] + 0.7152 * p0[1] + 0.0722 * p0[2];
              double l1 = 0.2126 * p1[0] + 0.7152 * p1[1] + 0.0722 * p1[2];
              double d = fabs(l1 - l0);
              if (d > max_d_flat) max_d_flat = d;
              sum2_flat += d * d;
              cnt_flat++;
            }
          }
          double rms_flat = sqrt(sum2_flat / (double)(cnt_flat > 0 ? cnt_flat : 1));
          printf("gles_render: v14b_scroll_shimmer_%dx flat_max=%.2f flat_rms=%.2f\n", sc_i, max_d_flat, rms_flat);
          CHECK(max_d_flat <= 3.0);
          free(fpx[0]); free(fpx[1]);
        }
        // V14c-DualSlot-MidSg: 2x blur=2.1pt tint=0x67 falls in 0.3 < sg <= 0.55 (sg~0.438).
        {
          V_SETUP(2);
          float mf21[MB_INST];
          memset(mf21, 0, sizeof mf21);
          mf21[0] = 14.0f; mf21[1] = 18.0f; mf21[2] = 132.0f; mf21[3] = 44.0f; mf21[4] = 22.0f;
          mf21[5] = 6.0f; mf21[6] = 1.0f; mf21[7] = 2.1f;
          mf21[8] = 253.0f / 255.0f; mf21[9] = 252.0f / 255.0f; mf21[10] = 253.0f / 255.0f; mf21[11] = 0x67 / 255.0f;
          mf21[12] = 0.6f; mf21[13] = 14.0f; mf21[15] = 1.0f; mf21[18] = (float)VW; mf21[19] = (float)VH; mf21[20] = -149.0f; mf21[21] = 20.0f;
          Grab g21;
          CHECK(grab_of(&g21, mf21, 0, 1, 1) == 1);
          CHECK(g21.dual_scale == 1 && g21.k == 1 && g21.sg > 0.30f && g21.sg <= 0.55f);
          CHECK(grab_blurred(&g21) == &lv[4]);
          double s21[3 * MB_INST];
          V_RECT(s21, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 0);
          V_RECT(s21 + MB_INST, 74, 0, 12, VH, 0, 0.05, 0.05, 0.05, 0);
          V_RECT(s21 + 2 * MB_INST, 14, 18, 132, 44, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -149);
          s21[2 * MB_INST + 4] = 22.0; s21[2 * MB_INST + 6] = 1.0; s21[2 * MB_INST + 7] = 2.1;
          s21[2 * MB_INST + 11] = 0x67 / 255.0; s21[2 * MB_INST + 12] = 0.6; s21[2 * MB_INST + 13] = 14.0;
          s21[2 * MB_INST + 15] = 1.0; s21[2 * MB_INST + 21] = 20.0; s21[2 * MB_INST + 22] = 0.06;
          glass_forget();
          gl_present(s21, 3, 1.0, 1.0, 1.0);
          unsigned char *p1 = pixels_of_fb(vfb);
          gl_present(s21, 3, 1.0, 1.0, 1.0);
          unsigned char *p2 = pixels_of_fb(vfb);
          unsigned char *cb = V_PX(p1, 80 * 2, 40 * 2);
          unsigned char *cw1 = V_PX(p1, 50 * 2, 40 * 2);
          double l_bar = 0.2126 * cb[0] + 0.7152 * cb[1] + 0.0722 * cb[2];
          double l_wh = 0.2126 * cw1[0] + 0.7152 * cw1[1] + 0.0722 * cw1[2];
          int cache_diff = 0;
          for (int py = 24 * 2; py < 56 * 2; py++) {
            for (int px = 30 * 2; px < 130 * 2; px++) {
              unsigned char *a1 = V_PX(p1, px, py), *a2 = V_PX(p2, px, py);
              for (int c = 0; c < 3; c++) {
                int d = abs((int)a1[c] - (int)a2[c]);
                if (d > cache_diff) cache_diff = d;
              }
            }
          }
          printf("gles_render: v14c_dual_slot_midsg sg=%.3f bar_L=%.1f wh_L=%.1f diff=%.1f cache_diff=%d\n",
                 g21.sg, l_bar, l_wh, l_wh - l_bar, cache_diff);
          CHECK(l_bar >= 185.0 && (l_wh - l_bar) <= 65.0 && cache_diff == 0);
          free(p1); free(p2);
        }
        // V15-Unified-V9-Gates: (1) 2x blur=4pt (k=2) flat 0.5 grey stays ~195 (no sRGB/linear mix corruption);
        // (2) Light 0x67 over 10% white bars on pure black stays <= 150 (no linear over-bloom on dark backdrop);
        // (3) Adaptive 0xFF solid over black vs white is identical (<= 1 LSB);
        // (4) Shared capture Light+Dark vs Dark+Light order-invariant (0 LSB diff);
        // (5) Dark 0x80 grayscale sweep Y=0..1 strictly monotonic & white <= 102;
        // (6) Overlay outside-shadow top-edge vertical profile smooth (sh_jump < 2.5).
        {
          V_SETUP(2);
          double fg[2 * MB_INST];
          V_RECT(fg, 0, 0, 160, 80, 0, 0.5, 0.5, 0.5, 0);
          V_RECT(fg + MB_INST, 14, 9, 132, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -151);
          fg[MB_INST + 4] = 31.0; fg[MB_INST + 6] = 1.0; fg[MB_INST + 7] = 4.0;
          fg[MB_INST + 11] = 0x67 / 255.0; fg[MB_INST + 12] = 0.6; fg[MB_INST + 13] = 14.0;
          fg[MB_INST + 15] = 1.0; fg[MB_INST + 21] = 20.0;
          glass_forget(); gl_present(fg, 2, 0.5, 0.5, 0.5);
          unsigned char *pfg = pixels_of_fb(vfb);
          unsigned char *cfg = V_PX(pfg, 80 * 2, 40 * 2);
          int k2_g = cfg[1];
          free(pfg);

          V_SETUP(3);
          double wb[6 * MB_INST];
          V_RECT(wb, 0, 0, 160, 80, 0, 0.0, 0.0, 0.0, 0);
          for (int bi = 0; bi < 4; bi++) V_RECT(wb + (1 + bi) * MB_INST, 0, 10 + bi * 20, 160, 2.0, 0, 1.0, 1.0, 1.0, 0);
          V_RECT(wb + 5 * MB_INST, 14, 9, 132, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -152);
          wb[5 * MB_INST + 4] = 31.0; wb[5 * MB_INST + 6] = 1.0; wb[5 * MB_INST + 7] = 1.2;
          wb[5 * MB_INST + 11] = 0x67 / 255.0; wb[5 * MB_INST + 12] = 0.6; wb[5 * MB_INST + 13] = 14.0;
          wb[5 * MB_INST + 15] = 1.0; wb[5 * MB_INST + 21] = 20.0;
          glass_forget(); gl_present(wb, 6, 0.0, 0.0, 0.0);
          unsigned char *pwb = pixels_of_fb(vfb);
          unsigned char *cwb = V_PX(pwb, 80 * 3, 40 * 3);
          int dark_bar_g = cwb[1];
          free(pwb);

          V_SETUP(2);
          int ad_diff = 0;
          unsigned char ad_c[2][3];
          for (int bi = 0; bi < 2; bi++) {
            double bgv = bi ? 1.0 : 0.0;
            V_RECT(fg, 0, 0, 160, 80, 0, bgv, bgv, bgv, 0);
            V_RECT(fg + MB_INST, 14, 9, 132, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -153 - bi);
            fg[MB_INST + 4] = 24.0; fg[MB_INST + 6] = 1.0; fg[MB_INST + 7] = 1.2;
            fg[MB_INST + 11] = 1.0; fg[MB_INST + 12] = 0.6; fg[MB_INST + 13] = 14.0;
            fg[MB_INST + 14] = -1.0; fg[MB_INST + 15] = 1.0; fg[MB_INST + 21] = 20.0;
            glass_forget(); gl_present(fg, 2, bgv, bgv, bgv);
            unsigned char *pad = pixels_of_fb(vfb);
            unsigned char *cad = V_PX(pad, 80 * 2, 40 * 2);
            ad_c[bi][0] = cad[0]; ad_c[bi][1] = cad[1]; ad_c[bi][2] = cad[2];
            free(pad);
          }
          for (int c = 0; c < 3; c++) { int d = abs((int)ad_c[0][c] - (int)ad_c[1][c]); if (d > ad_diff) ad_diff = d; }

          unsigned char *sord[2];
          for (int oi = 0; oi < 2; oi++) {
            double so[4 * MB_INST];
            V_RECT(so, 0, 0, 160, 80, 0, 0.95, 0.94, 0.91, 0);
            V_RECT(so + MB_INST, 0, 36, 160, 8, 0, 0.05, 0.05, 0.05, 0);
            int li = oi == 0 ? 2 : 3, di = oi == 0 ? 3 : 2;
            V_RECT(so + li * MB_INST, 8, 9, 64, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -156 - oi);
            so[li * MB_INST + 4] = 31.0; so[li * MB_INST + 6] = 1.0; so[li * MB_INST + 7] = 1.2;
            so[li * MB_INST + 11] = 0x67/255.0; so[li * MB_INST + 12] = 0.6; so[li * MB_INST + 13] = 14.0;
            so[li * MB_INST + 15] = 1.0; so[li * MB_INST + 21] = 20.0;
            V_RECT(so + di * MB_INST, 88, 9, 64, 62, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -156 - oi);
            so[di * MB_INST + 4] = 31.0; so[di * MB_INST + 6] = 1.0; so[di * MB_INST + 7] = 1.2;
            so[di * MB_INST + 11] = 0x67/255.0; so[di * MB_INST + 12] = 0.6; so[di * MB_INST + 13] = 14.0;
            so[di * MB_INST + 15] = 1.0; so[di * MB_INST + 21] = 20.0;
            glass_forget(); gl_present(so, 4, 0.95, 0.94, 0.91);
            sord[oi] = pixels_of_fb(vfb);
          }
          int ord_diff = 0;
          for (int i = 0; i < fb_w * fb_h * 4; i++) { int d = abs((int)sord[0][i] - (int)sord[1][i]); if (d > ord_diff) ord_diff = d; }
          free(sord[0]); free(sord[1]);

          int dark_mono_ok = 1;
          double prev_dl = -1.0, dark_y20_L = 0.0, dark_y40_L = 0.0, dark_mid_L = 0.0, dark_wt_L2 = 0.0;
          for (int gi = 0; gi <= 20; gi++) {
            double gv = (double)gi / 20.0;
            V_RECT(fg, 0, 0, 160, 80, 0, gv, gv, gv, 0);
            V_RECT(fg + MB_INST, 14, 9, 132, 62, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -160 - gi);
            fg[MB_INST + 4] = 24.0; fg[MB_INST + 6] = 1.0; fg[MB_INST + 7] = 14.0;
            fg[MB_INST + 11] = 0x80 / 255.0; fg[MB_INST + 12] = 0.6; fg[MB_INST + 13] = 20.0;
            fg[MB_INST + 14] = 0.0; fg[MB_INST + 15] = 1.0; fg[MB_INST + 21] = 16.0;
            glass_forget(); gl_present(fg, 2, gv, gv, gv);
            unsigned char *pd = pixels_of_fb(vfb);
            unsigned char *cd = V_PX(pd, 80 * 2, 40 * 2);
            double dl = 0.2126 * cd[0] + 0.7152 * cd[1] + 0.0722 * cd[2];
            if (prev_dl >= 0.0 && dl < prev_dl - 0.1) dark_mono_ok = 0;
            prev_dl = dl;
            if (gi == 4) dark_y20_L = dl;
            if (gi == 8) dark_y40_L = dl;
            if (gi == 11) dark_mid_L = dl;
            if (gi == 20) dark_wt_L2 = dl;
            free(pd);
          }

          int light_mono_ok = 1;
          double prev_ll = -1.0, light_blk_L = 0.0, light_y60_L = 0.0, light_y80_L = 0.0;
          for (int gi = 0; gi <= 20; gi++) {
            double gv = (double)gi / 20.0;
            V_RECT(fg, 0, 0, 160, 80, 0, gv, gv, gv, 0);
            V_RECT(fg + MB_INST, 14, 9, 132, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -200 - gi);
            fg[MB_INST + 4] = 24.0; fg[MB_INST + 6] = 1.0; fg[MB_INST + 7] = 14.0;
            fg[MB_INST + 11] = 0x80 / 255.0; fg[MB_INST + 12] = 0.6; fg[MB_INST + 13] = 20.0;
            fg[MB_INST + 14] = 0.0; fg[MB_INST + 15] = 1.0; fg[MB_INST + 21] = 16.0;
            glass_forget(); gl_present(fg, 2, gv, gv, gv);
            unsigned char *pl = pixels_of_fb(vfb);
            unsigned char *cl = V_PX(pl, 80 * 2, 40 * 2);
            double ll = 0.2126 * cl[0] + 0.7152 * cl[1] + 0.0722 * cl[2];
            if (prev_ll >= 0.0 && ll < prev_ll - 0.1) light_mono_ok = 0;
            prev_ll = ll;
            if (gi == 0) light_blk_L = ll;
            if (gi == 12) light_y60_L = ll;
            if (gi == 16) light_y80_L = ll;
            free(pl);
          }

          double chk_cr_blk = 0.0, chk_cr_blu = 0.0;
          {
            double row_b[3 * MB_INST];
            double acc_l = 0.2126 * pow((0x98/255.0 + 0.055)/1.055, 2.4)
                         + 0.7152 * pow((0x2E/255.0 + 0.055)/1.055, 2.4)
                         + 0.0722 * ((0x01/255.0) / 12.92);
            for (int bi = 0; bi < 2; bi++) {
              double br = 0.0, bg = bi ? (0x7A/255.0) : 0.0, bb = bi ? 1.0 : 0.0;
              V_RECT(row_b, 0, 0, 160, 80, 0, br, bg, bb, 0);
              V_RECT(row_b + MB_INST, 14, 9, 132, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -230 - bi);
              row_b[MB_INST + 4] = 24.0; row_b[MB_INST + 6] = 1.0; row_b[MB_INST + 7] = 14.0;
              row_b[MB_INST + 11] = 0x80 / 255.0; row_b[MB_INST + 12] = 0.6; row_b[MB_INST + 13] = 20.0;
              row_b[MB_INST + 14] = 0.0; row_b[MB_INST + 15] = 1.0; row_b[MB_INST + 21] = 16.0;
              V_RECT(row_b + 2 * MB_INST, 24, 22, 112, 36, 0, 0x24/255.0, 0x27/255.0, 0x2B/255.0, 0);
              row_b[2 * MB_INST + 4] = 14.0; row_b[2 * MB_INST + 11] = 0x0F / 255.0;
              glass_forget(); gl_present(row_b, 3, br, bg, bb);
              unsigned char *pr = pixels_of_fb(vfb);
              unsigned char *crp = V_PX(pr, 80 * 2, 40 * 2);
              double cr_r = crp[0] / 255.0, cr_g = crp[1] / 255.0, cr_b = crp[2] / 255.0;
              double lr = (cr_r <= 0.04045) ? cr_r / 12.92 : pow((cr_r + 0.055) / 1.055, 2.4);
              double lg = (cr_g <= 0.04045) ? cr_g / 12.92 : pow((cr_g + 0.055) / 1.055, 2.4);
              double lb = (cr_b <= 0.04045) ? cr_b / 12.92 : pow((cr_b + 0.055) / 1.055, 2.4);
              double row_l = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb;
              double hi = row_l > acc_l ? row_l : acc_l, lo = row_l > acc_l ? acc_l : row_l;
              double crv = (hi + 0.05) / (lo + 0.05);
              if (bi == 0) chk_cr_blk = crv; else chk_cr_blu = crv;
              free(pr);
            }
          }

          VW = 200; VH = 160;
          V_SETUP(3);
          double sh[3 * MB_INST];
          V_RECT(sh, 0, 0, 200, 160, 0, 244.0/255.0, 241.0/255.0, 234.0/255.0, 0);
          V_RECT(sh + MB_INST, 20, 40 + 6, 160, 100, 2, 0.0, 0.0, 0.0, 0);
          sh[MB_INST + 4] = 24.0; sh[MB_INST + 7] = 14.0; sh[MB_INST + 11] = 0x18 / 255.0;
          sh[MB_INST + 12] = 1.0; sh[MB_INST + 13] = 6.0;
          sh[MB_INST + 36] = 24.0; sh[MB_INST + 37] = 24.0; sh[MB_INST + 38] = 24.0; sh[MB_INST + 39] = 24.0;
          V_RECT(sh + 2 * MB_INST, 20, 40, 160, 100, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -190);
          sh[2 * MB_INST + 4] = 24.0; sh[2 * MB_INST + 6] = 1.0; sh[2 * MB_INST + 7] = 14.0;
          sh[2 * MB_INST + 11] = 0x80 / 255.0; sh[2 * MB_INST + 12] = 0.6; sh[2 * MB_INST + 13] = 20.0;
          sh[2 * MB_INST + 15] = 1.0; sh[2 * MB_INST + 21] = 16.0;
          sh[2 * MB_INST + 36] = 24.0; sh[2 * MB_INST + 37] = 24.0; sh[2 * MB_INST + 38] = 24.0; sh[2 * MB_INST + 39] = 24.0;
          glass_forget(); gl_present(sh, 3, 244.0/255.0, 241.0/255.0, 234.0/255.0);
          unsigned char *psh = pixels_of_fb(vfb);
          double sh_max_jump = 0.0;
          double sh_prev = -1.0;
          for (int py = 60; py <= 114; py++) {
            unsigned char *sp = V_PX(psh, 100 * 3, py);
            double sl = 0.2126 * sp[0] + 0.7152 * sp[1] + 0.0722 * sp[2];
            if (sh_prev >= 0.0 && (sl - sh_prev) > sh_max_jump) sh_max_jump = sl - sh_prev;
            sh_prev = sl;
          }
          free(psh);
          VW = 160; VH = 80;
          printf("gles_render: v15_unified_v9 k2_g=%d dark_bar_g=%d ad_ff_diff=%d ord_diff=%d dark_mono=%d d20=%.1f d40=%.1f mid55=%.1f wt=%.1f light_mono=%d blk=%.1f l60=%.1f l80=%.1f chk_blk=%.2f chk_blu=%.2f sh_jump=%.2f\n",
                 k2_g, dark_bar_g, ad_diff, ord_diff, dark_mono_ok, dark_y20_L, dark_y40_L, dark_mid_L, dark_wt_L2, light_mono_ok, light_blk_L, light_y60_L, light_y80_L, chk_cr_blk, chk_cr_blu, sh_max_jump);
          CHECK(abs(k2_g - 195) <= 2);
          CHECK(dark_bar_g <= 150);
          CHECK(ad_diff <= 1);
          CHECK(ord_diff == 0);
          CHECK(dark_mono_ok == 1 && dark_wt_L2 <= 102.0 && (dark_wt_L2 - dark_y40_L) >= 6.0 && (dark_wt_L2 - dark_y20_L) >= 24.0);
          CHECK(light_mono_ok == 1 && light_blk_L >= 198.0 && (light_y60_L - light_blk_L) >= 10.0 && (light_y80_L - light_blk_L) >= 26.0);
          CHECK(chk_cr_blk >= 3.0 && chk_cr_blu >= 3.0);
          CHECK(sh_max_jump < 2.5);
        }
        V_SETUP(2);
      }
    }

    #undef V_RECT
    #undef V_SETUP
    #undef V_PX
    surface = saved_surface;
    target_fb = saved_target;
    glBindFramebuffer(GL_FRAMEBUFFER, surface);
    glDeleteFramebuffers(1, &vfb);
    glDeleteTextures(1, &vtex);
    fb_w = saved_fb_w; fb_h = saved_fb_h; cur_w = saved_w; cur_h = saved_h; cur_scale = saved_s;
  }

  // Batched kind 11 (MB_PROG_PATH) fill + stroke in one instanced draw call: guards the unified segment loop
  // required for Android SwiftShader 4.0.0.1 (where split if/else texelFetch loops dropped strokes completely).
  {
    gl_setup();
    glBindFramebuffer(GL_FRAMEBUFFER, surface);
    double sh[3 * MB_INST];
    // 0: red filled square at (10, 10, 20 x 20), segs 0..3
    rect_at(sh, 10, 10, 20, 20, 11, 1.0, 0.2, 0.2, 0);
    sh[4] = 0.0;
    sh[12] = 0.0; sh[13] = 4.0; sh[14] = 0.0;
    // 1: blue stroked L-polyline at (40, 20, 40 x 30), hw = 3.0, segs 4..5
    rect_at(sh + MB_INST, 40, 20, 40, 30, 11, 0.08, 0.35, 0.77, 0);
    sh[MB_INST + 4] = 3.0;
    sh[MB_INST + 12] = 4.0; sh[MB_INST + 13] = 2.0; sh[MB_INST + 14] = 0.0;
    // 2: kind 12 data instance holding all 6 segments in slots {0, 2, 3, 4, 6, 7}
    double *d = sh + 2 * MB_INST;
    memset(d, 0, MB_INST * sizeof(double));
    d[5] = 12.0;
    // fill square edges (0..3)
    d[0] = 0.0; d[1] = 0.0; d[2] = 1.0; d[3] = 0.0;
    d[8] = 1.0; d[9] = 0.0; d[10] = 1.0; d[11] = 1.0;
    d[12] = 1.0; d[13] = 1.0; d[14] = 0.0; d[15] = 1.0;
    d[16] = 0.0; d[17] = 1.0; d[18] = 0.0; d[19] = 0.0;
    // stroke L segments (4..5): (44,26)->(76,26)->(76,44)
    d[24] = 0.1; d[25] = 0.2; d[26] = 0.9; d[27] = 0.2;
    d[28] = 0.9; d[29] = 0.2; d[30] = 0.9; d[31] = 0.8;

    gl_present(sh, 3, 1.0, 1.0, 1.0);
    CHECK(progs[MB_PROG_PATH].p != 0);
    CHECK(glGetError() == GL_NO_ERROR);
    unsigned char *px = pixels_of_fb(surface);
    #define PATH_AT(xpt, ypt) (px + ((size_t)(fb_h - 1 - (int)((ypt) * S)) * fb_w + (int)((xpt) * S)) * 4)
    unsigned char *fill_in = PATH_AT(20, 20);
    unsigned char *fill_out = PATH_AT(5, 20);
    unsigned char *st_h = PATH_AT(60, 26);
    unsigned char *st_c = PATH_AT(76, 26);
    unsigned char *st_v = PATH_AT(76, 35);
    unsigned char *st_out = PATH_AT(60, 35);
    CHECK(fill_in[0] > 240 && fill_in[1] < 70 && fill_in[2] < 70);
    CHECK(fill_out[0] > 250 && fill_out[1] > 250 && fill_out[2] > 250);
    CHECK(st_h[0] < 40 && st_h[1] > 70 && st_h[1] < 110 && st_h[2] > 180);
    CHECK(st_c[0] < 40 && st_c[1] > 70 && st_c[1] < 110 && st_c[2] > 180);
    CHECK(st_v[0] < 40 && st_v[1] > 70 && st_v[1] < 110 && st_v[2] > 180);
    CHECK(st_out[0] > 250 && st_out[1] > 250 && st_out[2] > 250);
    #undef PATH_AT
    free(px);
    printf("gles_render: path fill+stroke batch ok\n");
  }

  // Perf-51: Fix 1 (dark-mode atomic + origL<0.5 + kind0 pad_w<0 + 1<->2 switch + light scroll readback skip),
  // Fix 2 (top-bar donor delegation + 33rd cold capture donor pin + lens counterexample + cut_on multi-dirty parity),
  // Fix 3 (MB_PROG_UI vs MB_PROG_UI_AD / MB_PROG_PATH_AD split + vid 2/5 provoking-vertex invariant).
  {
    gl_setup();
    glBindFramebuffer(GL_FRAMEBUFFER, surface);
    static const unsigned char solid16[16] = {
      255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255
    };
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, atlas);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 4, 4, GL_RED, GL_UNSIGNED_BYTE, solid16);

    // --- Fix 3a: Lean VS program split ---
    double plain_ui[2 * MB_INST];
    rect_at(plain_ui, 4, 4, 16, 16, 0, 0.2, 0.4, 0.8, 0);
    rect_at(plain_ui + MB_INST, 24, 4, 12, 12, 10, 0.9, 0.2, 0.2, 0);
    plain_ui[MB_INST + 4] = 2.0;
    plain_ui[MB_INST + 12] = 0.1; plain_ui[MB_INST + 13] = 0.5;
    plain_ui[MB_INST + 14] = 0.9; plain_ui[MB_INST + 15] = 0.5;
    gl_present(plain_ui, 2, 0.1, 0.1, 0.1);
    CHECK(progs[MB_PROG_UI].p != 0);
    CHECK(progs[MB_PROG_UI_AD].p == 0);
    CHECK(progs[MB_PROG_PATH].p == 0);
    CHECK(progs[MB_PROG_PATH_AD].p == 0);

    // Adaptive kind 0 (pad_w < 0) triggers MB_PROG_UI_AD
    double ad_rect[MB_INST];
    rect_at(ad_rect, 10, 10, 20, 20, 0, 0.15, 0.15, 0.15, 0);
    ad_rect[11] = 0.2; ad_rect[21] = 20; ad_rect[22] = 20; ad_rect[23] = -20;
    gl_present(ad_rect, 1, 0.1, 0.1, 0.1);
    CHECK(progs[MB_PROG_UI_AD].p != 0);
    CHECK(progs[MB_PROG_PATH_AD].p == 0);

    // Adaptive kind 11 (pad_w != 0) triggers MB_PROG_PATH_AD
    double ad_path[2 * MB_INST];
    rect_at(ad_path, 10, 10, 20, 20, 11, 0.85, 0.85, 0.85, 0);
    ad_path[12] = 0.0; ad_path[13] = 4.0; ad_path[23] = -14.0;
    memset(ad_path + MB_INST, 0, MB_INST * sizeof(double));
    ad_path[MB_INST + 5] = 12.0;
    ad_path[MB_INST + 0] = 0; ad_path[MB_INST + 1] = 0; ad_path[MB_INST + 2] = 1; ad_path[MB_INST + 3] = 0;
    ad_path[MB_INST + 8] = 1; ad_path[MB_INST + 9] = 0; ad_path[MB_INST + 10] = 1; ad_path[MB_INST + 11] = 1;
    ad_path[MB_INST + 12] = 1; ad_path[MB_INST + 13] = 1; ad_path[MB_INST + 14] = 0; ad_path[MB_INST + 15] = 1;
    ad_path[MB_INST + 16] = 0; ad_path[MB_INST + 17] = 1; ad_path[MB_INST + 18] = 0; ad_path[MB_INST + 19] = 0;
    gl_present(ad_path, 2, 0.1, 0.1, 0.1);
    CHECK(progs[MB_PROG_PATH_AD].p != 0);

    // --- Fix 3b: Provoking-vertex flatshading invariant (vid 2 & vid 5 across both triangles + clipped edge) ---
    {
      double pv[3 * MB_INST];
      // Dark backdrop
      rect_at(pv, 0, 0, W, H, 0, 0.05, 0.05, 0.05, 0);
      // Capture glass spanning viewport so u_bd holds dark backdrop
      rect_at(pv + MB_INST, 0, 0, W, H, 5, 0, 0, 0, -51);
      pv[MB_INST + 6] = 1.0; pv[MB_INST + 7] = 4.0; pv[MB_INST + 11] = 0.0; pv[MB_INST + 15] = 1.0;
      pv[MB_INST + 22] = -1.0; pv[MB_INST + 54] = H; pv[MB_INST + 55] = 10.0;
      // Large bare-adaptive dark glyph (origL < 0.5 -> must invert bright on dark backdrop) partially clipped on right edge
      rect_at(pv + 2 * MB_INST, 20, 10, 90, 60, 7, 0.15, 0.15, 0.15, 0);
      pv[2 * MB_INST + 12] = 0.0; pv[2 * MB_INST + 13] = 0.0;
      pv[2 * MB_INST + 14] = 4.0 / MB_ATLAS; pv[2 * MB_INST + 15] = 4.0 / MB_ATLAS;
      pv[2 * MB_INST + 21] = 65.0; pv[2 * MB_INST + 22] = 40.0; pv[2 * MB_INST + 23] = bare_ink(45, 30);
      gl_present(pv, 3, 0.05, 0.05, 0.05);
      unsigned char *px = pixels_of_fb(surface);
      // Sample upper-left triangle (vid 0,1,2 -> driven by vid 2) and lower-right triangle (vid 3,4,5 -> driven by vid 5)
      unsigned char *tri1 = px + ((size_t)(fb_h - 1 - 22 * S) * fb_w + 30 * S) * 4;
      unsigned char *tri2 = px + ((size_t)(fb_h - 1 - 58 * S) * fb_w + 90 * S) * 4;
      CHECK(tri1[0] == tri2[0] && tri1[1] == tri2[1] && tri1[2] == tri2[2]);
      CHECK(tri1[0] > 180 && tri1[1] > 180 && tri1[2] > 180);
      free(px);
    }

    // --- Fix 1: Dark-mode atomic convergence (origL<0.5 glyph, kind 0 pad_w<0 rect, 1<->2 switch) ---
    {
      glass_forget();
      gl_set_fixed_dt(1.0 / 60.0);
      double dk[4 * MB_INST];
      // 0: backdrop (white initially)
      rect_at(dk, 0, 0, W, H, 0, 1.0, 1.0, 1.0, 0);
      // 1: dark adaptive liquid pill (is_dark=1, 0x67)
      rect_at(dk + MB_INST, 10, 10, 80, 40, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, -52);
      dk[MB_INST + 4] = 16.0; dk[MB_INST + 6] = 1.0; dk[MB_INST + 7] = 1.0;
      dk[MB_INST + 11] = 0x67 / 255.0; dk[MB_INST + 13] = 4.0; dk[MB_INST + 14] = -1.0; dk[MB_INST + 15] = 1.0;
      // 2: origL < 0.5 glyph inside dark pill
      rect_at(dk + 2 * MB_INST, 20, 22, 16, 16, 7, 0.2, 0.2, 0.2, 0);
      dk[2 * MB_INST + 14] = 4.0 / MB_ATLAS; dk[2 * MB_INST + 15] = 4.0 / MB_ATLAS;
      dk[2 * MB_INST + 21] = 50.0; dk[2 * MB_INST + 22] = 30.0; dk[2 * MB_INST + 23] = 40.0;
      // 3: kind 0 pad_w < 0 adaptive rect inside dark pill
      rect_at(dk + 3 * MB_INST, 55, 22, 20, 16, 0, 0.1, 0.1, 0.1, 0);
      dk[3 * MB_INST + 11] = 0.18;
      dk[3 * MB_INST + 21] = 50.0; dk[3 * MB_INST + 22] = 30.0; dk[3 * MB_INST + 23] = -40.0;

      gl_present(dk, 4, 1.0, 1.0, 1.0);
      CHECK(gl_adaptive_settling() == 0);

      // Flip backdrop white -> black: same-polarity dark (is_dark=1) eases smoothly over ~70ms and settles within 30 frames
      rect_at(dk, 0, 0, W, H, 0, 0.0, 0.0, 0.0, 0);
      gl_present(dk, 4, 0.0, 0.0, 0.0);
      CHECK(gl_adaptive_settling() == 1);
      for (int k = 0; k < 30; k++) gl_present(dk, 4, 0.0, 0.0, 0.0);
      CHECK(gl_adaptive_settling() == 0);
      unsigned char *px_f30 = pixels_of_fb(surface);
      for (int k = 0; k < 5; k++) gl_present(dk, 4, 0.0, 0.0, 0.0);
      unsigned char *px_f35 = pixels_of_fb(surface);
      CHECK(memcmp(px_f30, px_f35, (size_t)fb_w * fb_h * 4) == 0);
      free(px_f30); free(px_f35);

      // Mode switch 1 -> 2 (0x67 -> 0xA8, high opacity snaps on frame 1) and 2 -> 1 (eases smoothly) over white backdrop
      rect_at(dk, 0, 0, W, H, 0, 1.0, 1.0, 1.0, 0);
      for (int k = 0; k < 30; k++) gl_present(dk, 4, 1.0, 1.0, 1.0);
      CHECK(gl_adaptive_settling() == 0);
      dk[MB_INST + 11] = 0xE8 / 255.0; // near-solid (>= 0.88) snaps on frame 1
      gl_present(dk, 4, 1.0, 1.0, 1.0);
      CHECK(gl_adaptive_settling() == 0);
      unsigned char *px_m2_f1 = pixels_of_fb(surface);
      for (int k = 0; k < 10; k++) gl_present(dk, 4, 1.0, 1.0, 1.0);
      unsigned char *px_m2_f10 = pixels_of_fb(surface);
      CHECK(memcmp(px_m2_f1, px_m2_f10, (size_t)fb_w * fb_h * 4) == 0);
      free(px_m2_f1); free(px_m2_f10);
      dk[MB_INST + 11] = 0x67 / 255.0; // back to is_dark = 1
      gl_present(dk, 4, 1.0, 1.0, 1.0);
      CHECK(gl_adaptive_settling() == 1);
      for (int k = 0; k < 30; k++) gl_present(dk, 4, 1.0, 1.0, 1.0);
      CHECK(gl_adaptive_settling() == 0);

      // Light-mode consecutive active scroll skips readback while scrolling, resumes on first idle frame & converges <= 4 frames
      glass_forget();
      double lt[2 * MB_INST];
      rect_at(lt, 0, 0, W, H, 0, 0.9, 0.9, 0.9, 0);
      rect_at(lt + MB_INST, 10, 10, 80, 40, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -53);
      lt[MB_INST + 4] = 16.0; lt[MB_INST + 6] = 1.0; lt[MB_INST + 7] = 1.0;
      lt[MB_INST + 11] = 0x67 / 255.0; lt[MB_INST + 13] = 4.0; lt[MB_INST + 14] = -1.0; lt[MB_INST + 15] = 1.0;
      int rb_base = ad_rb_submitted_count;
      gl_present(lt, 2, 0.9, 0.9, 0.9);
      glFinish();
      CHECK(ad_rb_submitted_count == rb_base);
      int light_sid = -1;
      for (int i = 0; i < MB_ADAPTIVE_MAX; i++) {
        if (ad_slots[i].active && ad_slots[i].is_dark == 0) { light_sid = i; break; }
      }
      CHECK(light_sid >= 0);
      // Frame 1 (first change): submitted +1, mask & (1u << sid) set
      rect_at(lt, 2, 0, W, H, 0, 0.88, 0.88, 0.88, 0);
      gl_present(lt, 2, 0.9, 0.9, 0.9);
      glFinish();
      CHECK(ad_rb_submitted_count == rb_base + 1);
      CHECK((ad_rb_last_mask & (1u << light_sid)) != 0);
      // Frame 2 & 3 (consecutive scroll): submitted +0!
      for (int sf = 2; sf <= 3; sf++) {
        rect_at(lt, 2 * sf, 0, W, H, 0, 0.88 - 0.01 * sf, 0.88 - 0.01 * sf, 0.88 - 0.01 * sf, 0);
        gl_present(lt, 2, 0.9, 0.9, 0.9);
        glFinish();
        CHECK(ad_rb_submitted_count == rb_base + 1);
      }
      CHECK(gl_adaptive_settling() == 1);
      // Frame 4 (first idle settle frame): submitted +1, mask & (1u << sid) set, converges within 4 frames
      gl_adaptive_step();
      glFinish();
      CHECK(ad_rb_submitted_count == rb_base + 2);
      CHECK((ad_rb_last_mask & (1u << light_sid)) != 0);
      int steps = 1;
      while (gl_adaptive_settling() && steps < 4) {
        gl_adaptive_step();
        glFinish();
        steps++;
      }
      CHECK(gl_adaptive_settling() == 0);
      CHECK(steps <= 4);

      // Mixed-slot test: 1 static settling light slot + 1 actively scrolling light slot in same frame
      // -> ad_rb_last_mask includes ONLY the static settling slot bit and excludes the scrolling slot bit
      {
        glass_forget();
        double mx[4 * MB_INST];
        rect_at(mx, 0, 0, 56, H, 0, 0.9, 0.9, 0.9, 0);
        rect_at(mx + MB_INST, 56, 0, W - 56, H, 0, 0.9, 0.9, 0.9, 0);
        rect_at(mx + 2 * MB_INST, 6, 10, 36, 36, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -56);
        mx[2 * MB_INST + 4] = 14.0; mx[2 * MB_INST + 6] = 1.0; mx[2 * MB_INST + 7] = 1.0;
        mx[2 * MB_INST + 11] = 0x67 / 255.0; mx[2 * MB_INST + 13] = 4.0; mx[2 * MB_INST + 14] = -1.0; mx[2 * MB_INST + 15] = 1.0;
        rect_at(mx + 3 * MB_INST, 66, 10, 36, 36, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -57);
        mx[3 * MB_INST + 4] = 14.0; mx[3 * MB_INST + 6] = 1.0; mx[3 * MB_INST + 7] = 1.0;
        mx[3 * MB_INST + 11] = 0x67 / 255.0; mx[3 * MB_INST + 13] = 4.0; mx[3 * MB_INST + 14] = -1.0; mx[3 * MB_INST + 15] = 1.0;
        gl_present(mx, 4, 0.9, 0.9, 0.9);
        glFinish();
        int sid_a = -1, sid_b = -1;
        for (int i = 0; i < MB_ADAPTIVE_MAX; i++) {
          if (!ad_slots[i].active) continue;
          if (fabsf(ad_slots[i].cx - 24.0f) < 4.0f) sid_a = i;
          if (fabsf(ad_slots[i].cx - 84.0f) < 4.0f) sid_b = i;
        }
        CHECK(sid_a >= 0 && sid_b >= 0 && sid_a != sid_b);
        // Frame 1: both change -> both enter settling & record last_changed_serial
        rect_at(mx, 0, 0, 56, H, 0, 0.05, 0.05, 0.05, 0);
        rect_at(mx + MB_INST, 56, 0, W - 56, H, 0, 0.05, 0.05, 0.05, 0);
        int rb_m0 = ad_rb_submitted_count;
        gl_present(mx, 4, 0.9, 0.9, 0.9);
        glFinish();
        CHECK(ad_rb_submitted_count == rb_m0 + 1);
        CHECK((ad_rb_last_mask & (1u << sid_a)) != 0 && (ad_rb_last_mask & (1u << sid_b)) != 0);
        // Frame 2: left (sid_a) stays static & settling, right (sid_b) changes again (consec_scroll)
        rect_at(mx + MB_INST, 56, 0, W - 56, H, 0, 0.15, 0.15, 0.15, 0);
        gl_present(mx, 4, 0.9, 0.9, 0.9);
        glFinish();
        CHECK(ad_rb_submitted_count == rb_m0 + 2);
        CHECK((ad_rb_last_mask & (1u << sid_a)) != 0);
        CHECK((ad_rb_last_mask & (1u << sid_b)) == 0);
      }

      // Concentric light+dark adaptive slot polarity matching in BOTH draw orders (light-then-dark & dark-then-light):
      // while light slot is actively settling (dt=1/60), dark glass, light ink, dark neutral ink, and kind==0 selection
      // highlight on the exposed dark capsule region must all snap immediately on frame 1 (<= 1 LSB vs frame 30).
      for (int order = 0; order < 2; order++) {
        glass_forget();
        double cc[6 * MB_INST];
        // 0: backdrop (white initially)
        rect_at(cc, 0, 0, W, H, 0, 1.0, 1.0, 1.0, 0);
        int l_idx = (order == 0) ? 1 : 2;
        int d_idx = (order == 0) ? 2 : 1;
        // Narrower concentric light glass (x=34..66, center 50,30) + wider concentric dark glass (x=10..90, center 50,30)
        // so both share exact center (50,30) while x=10..34 and x=66..90 expose dark glass cleanly in both orders.
        rect_at(cc + l_idx * MB_INST, 34, 10, 32, 40, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -58);
        cc[l_idx * MB_INST + 4] = 16.0; cc[l_idx * MB_INST + 6] = 1.0; cc[l_idx * MB_INST + 7] = 1.0;
        cc[l_idx * MB_INST + 11] = 0x67 / 255.0; cc[l_idx * MB_INST + 13] = 4.0; cc[l_idx * MB_INST + 14] = -1.0; cc[l_idx * MB_INST + 15] = 1.0;
        rect_at(cc + d_idx * MB_INST, 10, 10, 80, 40, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, -59);
        cc[d_idx * MB_INST + 4] = 16.0; cc[d_idx * MB_INST + 6] = 1.0; cc[d_idx * MB_INST + 7] = 1.0;
        cc[d_idx * MB_INST + 11] = 0x67 / 255.0; cc[d_idx * MB_INST + 13] = 4.0; cc[d_idx * MB_INST + 14] = -1.0; cc[d_idx * MB_INST + 15] = 1.0;
        // 3: light neutral ink glyph inside left exposed dark glass (pad.yz = 50,30 concentric center)
        rect_at(cc + 3 * MB_INST, 14, 24, 10, 12, 7, 0.93, 0.93, 0.93, 0);
        cc[3 * MB_INST + 14] = 4.0 / MB_ATLAS; cc[3 * MB_INST + 15] = 4.0 / MB_ATLAS;
        cc[3 * MB_INST + 21] = 50.0; cc[3 * MB_INST + 22] = 30.0; cc[3 * MB_INST + 23] = 40.0;
        // 4: dark neutral ink glyph inside right exposed dark glass (pad.yz = 50,30, pad.w = 40)
        rect_at(cc + 4 * MB_INST, 70, 24, 10, 12, 7, 0.20, 0.20, 0.20, 0);
        cc[4 * MB_INST + 14] = 4.0 / MB_ATLAS; cc[4 * MB_INST + 15] = 4.0 / MB_ATLAS;
        cc[4 * MB_INST + 21] = 50.0; cc[4 * MB_INST + 22] = 30.0; cc[4 * MB_INST + 23] = 40.0;
        // 5: kind == 0 selection highlight inside right exposed dark glass (pad.yz = 50,30, pad.w = -40)
        rect_at(cc + 5 * MB_INST, 80, 22, 8, 16, 0, 0.15, 0.15, 0.15, 0);
        cc[5 * MB_INST + 11] = 0.20;
        cc[5 * MB_INST + 21] = 50.0; cc[5 * MB_INST + 22] = 30.0; cc[5 * MB_INST + 23] = -40.0;
        // Frame 0: white backdrop
        gl_present(cc, 6, 1.0, 1.0, 1.0);
        // Frame 1 (dt = 1/60): flip backdrop to black -> light slot is mid-settle, dark glass & all 3 elements must snap!
        rect_at(cc, 0, 0, W, H, 0, 0.0, 0.0, 0.0, 0);
        gl_present(cc, 6, 0.0, 0.0, 0.0);
        unsigned char *px1 = pixels_of_fb(surface);
        for (int k = 0; k < 30; k++) gl_present(cc, 6, 0.0, 0.0, 0.0);
        unsigned char *px30 = pixels_of_fb(surface);
        // Sample dark glass (28,30), light ink (19,30), dark neutral ink (75,30), selection highlight (84,30)
        size_t dg_off = ((size_t)(fb_h - 1 - 30 * S) * fb_w + 28 * S) * 4;
        size_t in_off = ((size_t)(fb_h - 1 - 30 * S) * fb_w + 19 * S) * 4;
        size_t dn_off = ((size_t)(fb_h - 1 - 30 * S) * fb_w + 75 * S) * 4;
        size_t hl_off = ((size_t)(fb_h - 1 - 30 * S) * fb_w + 84 * S) * 4;
        CHECK(px1[dg_off] < 90 && px1[in_off] > 200);
        // Dark slot over black backdrop eases smoothly toward 0.0 (latch=64), never inverting dark neutral ink or highlight.
        CHECK(px1[dn_off] < 90 && px1[hl_off] < 90);
        CHECK(px30[dg_off] < 70 && px30[in_off] > 200);
        CHECK(abs((int)px1[in_off] - (int)px30[in_off]) <= 1);
        CHECK(abs((int)px1[dn_off] - (int)px30[dn_off]) <= 1);
        CHECK(abs((int)px1[hl_off] - (int)px30[hl_off]) <= 8);
        free(px1); free(px30);
      }
      // Shared-capture (same tid, Glass::sharing()) concentric identical-box light-then-dark overlap:
      // dark neutral ink (0.20) & kind==0 selection highlight (0.15) at the shared center must select the topmost
      // dark capsule slot (stay unlifted <90 and <=1 LSB frame 1 vs frame 30 while light slot settles).
      {
        glass_forget();
        double sh[5 * MB_INST];
        rect_at(sh, 0, 0, W, H, 0, 1.0, 1.0, 1.0, 0);
        // 1: light glass (10..90, 10..50, merge=0, tid=-60)
        rect_at(sh + MB_INST, 10, 10, 80, 40, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -60);
        sh[MB_INST + 4] = 16.0; sh[MB_INST + 6] = 1.0; sh[MB_INST + 7] = 1.0;
        sh[MB_INST + 11] = 0x67 / 255.0; sh[MB_INST + 13] = 4.0; sh[MB_INST + 14] = -1.0; sh[MB_INST + 15] = 1.0;
        // 2: concentric identical-box dark glass sharing tid=-60 (drawn on top of light glass)
        rect_at(sh + 2 * MB_INST, 10, 10, 80, 40, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, -60);
        sh[2 * MB_INST + 4] = 16.0; sh[2 * MB_INST + 6] = 1.0; sh[2 * MB_INST + 7] = 1.0;
        sh[2 * MB_INST + 11] = 0x67 / 255.0; sh[2 * MB_INST + 13] = 4.0; sh[2 * MB_INST + 14] = -1.0; sh[2 * MB_INST + 15] = 1.0;
        // 3: dark neutral ink (0.20) at shared center (x=40..50, y=24..36 -> sample at 45,30)
        rect_at(sh + 3 * MB_INST, 40, 24, 10, 12, 7, 0.20, 0.20, 0.20, 0);
        sh[3 * MB_INST + 14] = 4.0 / MB_ATLAS; sh[3 * MB_INST + 15] = 4.0 / MB_ATLAS;
        sh[3 * MB_INST + 21] = 50.0; sh[3 * MB_INST + 22] = 30.0; sh[3 * MB_INST + 23] = 40.0;
        // 4: kind==0 selection highlight (0.15, a=0.20) at shared center (x=52..60, y=22..38 -> sample at 56,30)
        rect_at(sh + 4 * MB_INST, 52, 22, 8, 16, 0, 0.15, 0.15, 0.15, 0);
        sh[4 * MB_INST + 11] = 0.20;
        sh[4 * MB_INST + 21] = 50.0; sh[4 * MB_INST + 22] = 30.0; sh[4 * MB_INST + 23] = -40.0;
        gl_present(sh, 5, 1.0, 1.0, 1.0);
        rect_at(sh, 0, 0, W, H, 0, 0.0, 0.0, 0.0, 0);
        gl_present(sh, 5, 0.0, 0.0, 0.0);
        unsigned char *px1 = pixels_of_fb(surface);
        for (int k = 0; k < 30; k++) gl_present(sh, 5, 0.0, 0.0, 0.0);
        unsigned char *px30 = pixels_of_fb(surface);
        size_t dn_off = ((size_t)(fb_h - 1 - 30 * S) * fb_w + 45 * S) * 4;
        size_t hl_off = ((size_t)(fb_h - 1 - 30 * S) * fb_w + 56 * S) * 4;
        CHECK(px1[dn_off] < 90 && px1[hl_off] < 90);
        CHECK(abs((int)px1[dn_off] - (int)px30[dn_off]) <= 1);
        CHECK(abs((int)px1[hl_off] - (int)px30[hl_off]) <= 8);
        free(px1); free(px30);
      }
      // Interleaved shared-capture (Glass::sharing()) order:
      // [dark glass (10..90, tid=-61), 1pt highlight (67..68, 1pt gap from 34..66), light glass (34..66, tid=-61),
      //  dark neutral ink inside light glass (46..54)].
      // Highlight drawn BEFORE light glass must read ONLY the dark slot (snap on frame 1, <=1 LSB vs frame 30),
      // while ink drawn AFTER light glass must advance to the light slot (settle smoothly from frame 1 to frame 30).
      {
        glass_forget();
        double iv[5 * MB_INST];
        rect_at(iv, 0, 0, W, H, 0, 1.0, 1.0, 1.0, 0);
        // 1: wide dark glass [10, 90] (tid=-61)
        rect_at(iv + MB_INST, 10, 10, 80, 40, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, -61);
        iv[MB_INST + 4] = 16.0; iv[MB_INST + 6] = 1.0; iv[MB_INST + 7] = 1.0;
        iv[MB_INST + 11] = 0x67 / 255.0; iv[MB_INST + 13] = 4.0; iv[MB_INST + 14] = -1.0; iv[MB_INST + 15] = 1.0;
        // 2: 1pt selection highlight [67, 68] on exposed dark glass (1pt outside [34,66], drawn BEFORE light glass!)
        rect_at(iv + 2 * MB_INST, 67, 22, 1, 16, 0, 0.15, 0.15, 0.15, 0);
        iv[2 * MB_INST + 11] = 0.20;
        iv[2 * MB_INST + 21] = 50.0; iv[2 * MB_INST + 22] = 30.0; iv[2 * MB_INST + 23] = -40.0;
        // 3: narrow concentric light glass [34, 66] sharing tid=-61 (clear-invert opt-in)
        rect_at(iv + 3 * MB_INST, 34, 10, 32, 40, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -61);
        iv[3 * MB_INST + 4] = 16.0; iv[3 * MB_INST + 6] = -1.0; iv[3 * MB_INST + 7] = 1.0;
        iv[3 * MB_INST + 11] = 0x67 / 255.0; iv[3 * MB_INST + 13] = 4.0; iv[3 * MB_INST + 14] = -1.0; iv[3 * MB_INST + 15] = 1.0;
        // 4: dark neutral ink [46, 54] drawn AFTER light glass inside [34, 66]
        rect_at(iv + 4 * MB_INST, 46, 24, 8, 12, 7, 0.20, 0.20, 0.20, 0);
        iv[4 * MB_INST + 14] = 4.0 / MB_ATLAS; iv[4 * MB_INST + 15] = 4.0 / MB_ATLAS;
        iv[4 * MB_INST + 21] = 50.0; iv[4 * MB_INST + 22] = 30.0; iv[4 * MB_INST + 23] = 16.0;
        gl_present(iv, 5, 1.0, 1.0, 1.0);
        rect_at(iv, 0, 0, W, H, 0, 0.0, 0.0, 0.0, 0);
        gl_present(iv, 5, 0.0, 0.0, 0.0);
        unsigned char *px1 = pixels_of_fb(surface);
        for (int k = 0; k < 30; k++) gl_present(iv, 5, 0.0, 0.0, 0.0);
        unsigned char *px30 = pixels_of_fb(surface);
        size_t hl_off = ((size_t)(fb_h - 1 - 30 * S) * fb_w + (size_t)lround(67.5 * S)) * 4;
        size_t li_off = ((size_t)(fb_h - 1 - 30 * S) * fb_w + 50 * S) * 4;
        CHECK(px1[hl_off] < 90);
        CHECK(abs((int)px1[hl_off] - (int)px30[hl_off]) <= 8);
        // Ink drawn after light glass advanced to the settling light slot: moves smoothly from mid-settle to lifted (>180)
        CHECK(px30[li_off] > 180 && abs((int)px30[li_off] - (int)px1[li_off]) > 20);
        free(px1); free(px30);
      }
      gl_set_fixed_dt(0.0);
    }

    // --- Fix 2a: Top-bar delegation hit test (tight back_pill capture + WCAG CR >= 4.5 on light & dark) ---
    {
      glass_forget();
      for (int dark_bg = 0; dark_bg <= 1; dark_bg++) {
        double bgv = dark_bg ? 0.06 : 0.94;
        double tb[4 * MB_INST];
        rect_at(tb, 0, 0, W, H, 0, bgv, bgv, bgv, 0);
        // Pure progressive donor covering top bar (0, 0, W, 48)
        rect_at(tb + MB_INST, 0, 0, W, 48, 5, 0, 0, 0, -61);
        tb[MB_INST + 6] = 1.0; tb[MB_INST + 7] = 6.0; tb[MB_INST + 11] = 0.0; tb[MB_INST + 15] = 1.0;
        tb[MB_INST + 22] = -1.0; tb[MB_INST + 54] = 48.0; tb[MB_INST + 55] = 24.0;
        // Small 20x20 back pill (tid=-62) on left
        rect_at(tb + 2 * MB_INST, 4, 14, 20, 20, 6, 0.14, 0.14, 0.15, -62);
        tb[2 * MB_INST + 4] = 10.0; tb[2 * MB_INST + 6] = 1.0; tb[2 * MB_INST + 7] = 1.4;
        tb[2 * MB_INST + 11] = 0.4; tb[2 * MB_INST + 14] = -1.0; tb[2 * MB_INST + 15] = 1.0;
        tb[2 * MB_INST + 21] = 4.0; tb[2 * MB_INST + 23] = 2.0;
        // Bare-adaptive title glyph on right (x=54..66, y=16..28, pad_w=-12)
        rect_at(tb + 3 * MB_INST, 54, 16, 12, 12, 7, 0.9, 0.9, 0.9, 0);
        tb[3 * MB_INST + 14] = 4.0 / MB_ATLAS; tb[3 * MB_INST + 15] = 4.0 / MB_ATLAS;
        tb[3 * MB_INST + 21] = 60.0; tb[3 * MB_INST + 22] = 22.0; tb[3 * MB_INST + 23] = bare_ink(12.0, 12.0);

        gl_present(tb, 4, bgv, bgv, bgv);
        CHECK(donor_delegated_count == 1);
        CHECK(donor_of_buf[3] == -61);
        // Back pill capture width stays tight (NOT expanded across title at x=54..66!)
        Grab gm_del, gm_raw;
        CHECK(grab_of_with_donors(&gm_del, fbuf, 2, 3, 4, donor_of_buf) == 1);
        CHECK(grab_of(&gm_raw, fbuf, 2, 3, 4) == 1);
        CHECK(gm_del.w < gm_raw.w);
        CHECK(gm_del.w <= (int)ceilf((20.0f + 2.0f * (3.0f * 1.4f + 4.0f + 2.0f + 2.0f + 2.0f)) * S) + 4);
        // Verify title ink achieves WCAG CR >= 4.5 against backdrop
        unsigned char *px = pixels_of_fb(surface);
        unsigned char *tp = px + ((size_t)(fb_h - 1 - 22 * S) * fb_w + 60 * S) * 4;
        double fg_lin = pow(tp[0] / 255.0, 2.2);
        double bg_lin = pow(bgv, 2.2);
        double cr = (fmax(fg_lin, bg_lin) + 0.05) / (fmin(fg_lin, bg_lin) + 0.05);
        CHECK(cr >= 4.5);
        free(px);
      }
    }

    // --- Fix 2b: 33rd cold capture eviction test (donor slot pinned over opposite-brightness white region, 0 LSB diff, blurs >= 33) ---
    {
      glass_forget();
      // Reference: white region behind back pill & filler zone + dark 0.05 behind title, donor + back pill + bare title
      double ref[6 * MB_INST];
      rect_at(ref, 0, 0, W, H, 0, 1.0, 1.0, 1.0, 0);
      rect_at(ref + MB_INST, 32, 0, W - 32, 50, 0, 0.05, 0.05, 0.05, 0);
      rect_at(ref + 2 * MB_INST, 0, 0, W, 48, 5, 0, 0, 0, -70);
      ref[2 * MB_INST + 6] = 1.0; ref[2 * MB_INST + 7] = 6.0; ref[2 * MB_INST + 11] = 0.0; ref[2 * MB_INST + 15] = 1.0;
      ref[2 * MB_INST + 22] = -1.0; ref[2 * MB_INST + 54] = 48.0; ref[2 * MB_INST + 55] = 24.0;
      rect_at(ref + 3 * MB_INST, 4, 14, 16, 16, 6, 0.14, 0.14, 0.15, -71);
      ref[3 * MB_INST + 4] = 8.0; ref[3 * MB_INST + 6] = 1.0; ref[3 * MB_INST + 7] = 1.4;
      ref[3 * MB_INST + 11] = 0.4; ref[3 * MB_INST + 14] = -1.0; ref[3 * MB_INST + 15] = 1.0;
      ref[3 * MB_INST + 21] = 4.0; ref[3 * MB_INST + 23] = 2.0;
      rect_at(ref + 4 * MB_INST, 54, 16, 12, 12, 7, 0.2, 0.2, 0.2, 0);
      ref[4 * MB_INST + 14] = 4.0 / MB_ATLAS; ref[4 * MB_INST + 15] = 4.0 / MB_ATLAS;
      ref[4 * MB_INST + 21] = 60.0; ref[4 * MB_INST + 22] = 22.0; ref[4 * MB_INST + 23] = bare_ink(12.0, 12.0);
      gl_present(ref, 5, 1.0, 1.0, 1.0);
      unsigned char *ref_px = pixels_of_fb(surface);

      // Stress: donor + 31 distinct cold glasses over bright white below y=52 + 1 cold back pill over bright white + bare title (33 cold captures!)
      glass_forget();
      int b0 = blurs_made;
      double *st = calloc(36 * MB_INST, sizeof(double));
      memcpy(st, ref, 3 * MB_INST * sizeof(double));
      for (int i = 0; i < 31; i++) {
        double *g = st + (size_t)(3 + i) * MB_INST;
        rect_at(g, 2 + (i % 11) * 8, 51 + (i / 11) * 7, 6, 5, 5, 0.5, 0.5, 0.5, -(80 + i));
        g[6] = 1.0; g[7] = 2.0; g[11] = 0.2; g[15] = 1.0;
      }
      memcpy(st + 34 * MB_INST, ref + 3 * MB_INST, 2 * MB_INST * sizeof(double));
      gl_present(st, 36, 1.0, 1.0, 1.0);
      CHECK(donor_delegated_count == 1);
      CHECK(blurs_made - b0 >= 33);
      unsigned char *st_px = pixels_of_fb(surface);
      // Compare title region pixel-for-pixel (0 LSB diff! Title must stay bright white > 180 over dark backdrop)
      for (int y = 16 * S; y < 28 * S; y++) {
        for (int x = 54 * S; x < 66 * S; x++) {
          size_t off = ((size_t)(fb_h - 1 - y) * fb_w + x) * 4;
          CHECK(ref_px[off + 0] == st_px[off + 0] && ref_px[off + 1] == st_px[off + 1] &&
                ref_px[off + 2] == st_px[off + 2]);
        }
      }
      unsigned char *tc = st_px + ((size_t)(fb_h - 1 - 22 * S) * fb_w + 60 * S) * 4;
      CHECK(tc[0] > 180 && tc[1] > 180 && tc[2] > 180);
      free(ref_px); free(st_px); free(st);
    }

    // --- Fix 2b2: Top-level unique pure kind==5 donor (tid=-140) + kind==8 lens child also tagged tid=-140 -> MUST delegate! ---
    {
      glass_forget();
      double lt2[6 * MB_INST];
      rect_at(lt2, 0, 0, W, H, 0, 0.05, 0.05, 0.05, 0);
      rect_at(lt2 + MB_INST, 0, 0, W, 48, 5, 0, 0, 0, -140);
      lt2[MB_INST + 6] = 1.0; lt2[MB_INST + 7] = 6.0; lt2[MB_INST + 11] = 0.0; lt2[MB_INST + 15] = 1.0;
      lt2[MB_INST + 22] = -1.0; lt2[MB_INST + 54] = 48.0; lt2[MB_INST + 55] = 24.0;
      // Non-overlapping kind==8 lens at bottom (y=60..76) with child sharing tid=-140
      rect_at(lt2 + 2 * MB_INST, 4, 60, 20, 16, 8, 1, 1, 1, 0);
      lt2[2 * MB_INST + 7] = 1.0; lt2[2 * MB_INST + 11] = 1.0; lt2[2 * MB_INST + 12] = 1.0; lt2[2 * MB_INST + 15] = 1.0;
      rect_at(lt2 + 3 * MB_INST, 4, 60, 20, 16, 5, 0, 0, 0, -140);
      lt2[3 * MB_INST + 6] = 1.0; lt2[3 * MB_INST + 7] = 2.0; lt2[3 * MB_INST + 11] = 0.0; lt2[3 * MB_INST + 15] = 1.0;
      rect_at(lt2 + 4 * MB_INST, 4, 14, 20, 20, 6, 0.14, 0.14, 0.15, -141);
      lt2[4 * MB_INST + 4] = 10.0; lt2[4 * MB_INST + 6] = 1.0; lt2[4 * MB_INST + 7] = 1.4;
      lt2[4 * MB_INST + 11] = 0.4; lt2[4 * MB_INST + 14] = -1.0; lt2[4 * MB_INST + 15] = 1.0;
      lt2[4 * MB_INST + 21] = 4.0; lt2[4 * MB_INST + 23] = 2.0;
      rect_at(lt2 + 5 * MB_INST, 54, 16, 12, 12, 7, 0.2, 0.2, 0.2, 0);
      lt2[5 * MB_INST + 14] = 4.0 / MB_ATLAS; lt2[5 * MB_INST + 15] = 4.0 / MB_ATLAS;
      lt2[5 * MB_INST + 21] = 60.0; lt2[5 * MB_INST + 22] = 22.0; lt2[5 * MB_INST + 23] = bare_ink(12.0, 12.0);
      gl_present(lt2, 6, 0.05, 0.05, 0.05);
      CHECK(donor_delegated_count > 0);
      CHECK(donor_of_buf[5] == -140);
    }

    // --- Fix 2b3: Textured-backdrop top-bar delegation ON vs forced OFF (donor_of=NULL) pixel parity + occlusion margin ---
    {
      glass_forget();
      double tx[9 * MB_INST];
      // Alternating light/dark stripes behind top bar
      for (int si = 0; si < 6; si++) {
        double sv = (si & 1) ? 0.95 : 0.05;
        rect_at(tx + si * MB_INST, si * 20, 0, 20, H, 0, sv, sv, sv, 0);
      }
      // Pure progressive blur donor
      rect_at(tx + 6 * MB_INST, 0, 0, W, 48, 5, 0, 0, 0, -142);
      tx[6 * MB_INST + 6] = 1.0; tx[6 * MB_INST + 7] = 6.0; tx[6 * MB_INST + 11] = 0.0; tx[6 * MB_INST + 15] = 1.0;
      tx[6 * MB_INST + 22] = -1.0; tx[6 * MB_INST + 54] = 48.0; tx[6 * MB_INST + 55] = 24.0;
      // 20x20 back pill
      rect_at(tx + 7 * MB_INST, 4, 14, 20, 20, 6, 0.14, 0.14, 0.15, -143);
      tx[7 * MB_INST + 4] = 10.0; tx[7 * MB_INST + 6] = 1.0; tx[7 * MB_INST + 7] = 1.4;
      tx[7 * MB_INST + 11] = 0.4; tx[7 * MB_INST + 14] = -1.0; tx[7 * MB_INST + 15] = 1.0;
      tx[7 * MB_INST + 21] = 4.0; tx[7 * MB_INST + 23] = 2.0;
      // Bare title glyph over dark stripe (x=42..54 inside x=40..60 dark stripe)
      rect_at(tx + 8 * MB_INST, 42, 16, 12, 12, 7, 0.9, 0.9, 0.9, 0);
      tx[8 * MB_INST + 14] = 4.0 / MB_ATLAS; tx[8 * MB_INST + 15] = 4.0 / MB_ATLAS;
      tx[8 * MB_INST + 21] = 48.0; tx[8 * MB_INST + 22] = 22.0; tx[8 * MB_INST + 23] = bare_ink(12.0, 12.0);

      donor_force_off = 0;
      gl_present(tx, 8, 0.05, 0.05, 0.05);
      unsigned char *px_bg = pixels_of_fb(surface);

      glass_forget();
      donor_force_off = 0;
      gl_present(tx, 9, 0.05, 0.05, 0.05);
      CHECK(donor_delegated_count == 1);
      unsigned char *px_on = pixels_of_fb(surface);

      glass_forget();
      donor_force_off = 1;
      gl_present(tx, 9, 0.05, 0.05, 0.05);
      CHECK(donor_delegated_count == 0);
      unsigned char *px_off = pixels_of_fb(surface);
      donor_force_off = 0;

      int max_ch_diff = 0;
      for (int y = 16 * S; y < 28 * S; y++) {
        for (int x = 42 * S; x < 54 * S; x++) {
          size_t off = ((size_t)(fb_h - 1 - y) * fb_w + x) * 4;
          for (int c = 0; c < 3; c++) {
            int d = abs((int)px_on[off + c] - (int)px_off[off + c]);
            if (d > max_ch_diff) max_ch_diff = d;
          }
        }
      }
      size_t ctr_off = ((size_t)(fb_h - 1 - 22 * S) * fb_w + 48 * S) * 4;
      unsigned char *c_bg = px_bg + ctr_off;
      unsigned char *c_on = px_on + ctr_off;
      unsigned char *c_off = px_off + ctr_off;
      double y_bg = wcag_luma_u8(c_bg[0], c_bg[1], c_bg[2]);
      double y_on = wcag_luma_u8(c_on[0], c_on[1], c_on[2]);
      double y_off = wcag_luma_u8(c_off[0], c_off[1], c_off[2]);
      double cr_on = (fmax(y_on, y_bg) + 0.05) / (fmin(y_on, y_bg) + 0.05);
      double cr_off = (fmax(y_off, y_bg) + 0.05) / (fmin(y_off, y_bg) + 0.05);
      printf("gles_render: perf-51 textured parity cr_on=%.2f cr_off=%.2f max_ch_diff=%d bg=(%u,%u,%u)\n",
             cr_on, cr_off, max_ch_diff, c_bg[0], c_bg[1], c_bg[2]);
      CHECK(max_ch_diff <= 1);
      CHECK(cr_on >= 4.5 && cr_off >= 4.5);
      free(px_bg); free(px_on); free(px_off);

      // Scrolling bright-card ON/OFF polarity-flip scenario (CHAT_SCROLL_12F):
      // Sweep a bright card (0.85) band across the blur=8.5 progressive top bar until delegated (ON) and
      // non-delegated (OFF, extra 1.4pt pill blur) straddle WCAG Lbg=0.1792 and flip title polarity at (72,25),
      // then assert actual ON/OFF opposite polarity AND ON contrast >= 4.5 against hidden-title composited bg.
      {
        int found_flip = 0;
        double best_cr_on = 0.0, best_cr_off = 0.0, best_lbg = 0.0;
        int flip_edge = -1;
        unsigned char flip_on = 0, flip_off = 0;
        size_t boff = ((size_t)(fb_h - 1 - 25 * S) * fb_w + 72 * S) * 4;
        for (int cy = 0; cy <= 46 && !found_flip; cy++) {
          double bc[5 * MB_INST];
          rect_at(bc, 0, 0, W, H, 0, 0.06, 0.06, 0.06, 0);
          // Bright card (0.85) starting at y=cy across title column (x=50..W)
          rect_at(bc + MB_INST, 50, (double)cy, W - 50, H - cy, 0, 0.85, 0.85, 0.85, 0);
          // Progressive blur=8.5 top bar donor
          rect_at(bc + 2 * MB_INST, 0, 0, W, 56, 5, 0, 0, 0, -146);
          bc[2 * MB_INST + 6] = 1.0; bc[2 * MB_INST + 7] = 8.5; bc[2 * MB_INST + 11] = 0.0; bc[2 * MB_INST + 15] = 1.0;
          bc[2 * MB_INST + 22] = -1.0; bc[2 * MB_INST + 54] = 56.0; bc[2 * MB_INST + 55] = 28.0;
          // 40x40 back pill (blur=1.4) on left
          rect_at(bc + 3 * MB_INST, 4, 8, 40, 40, 6, 0.14, 0.14, 0.15, -147);
          bc[3 * MB_INST + 4] = 20.0; bc[3 * MB_INST + 6] = 1.0; bc[3 * MB_INST + 7] = 1.4;
          bc[3 * MB_INST + 11] = 0.4; bc[3 * MB_INST + 14] = -1.0; bc[3 * MB_INST + 15] = 1.0;
          bc[3 * MB_INST + 21] = 4.0; bc[3 * MB_INST + 23] = 2.0;
          // Bare adaptive light title glyph (x=64..80, y=18..32 -> center 72,25)
          rect_at(bc + 4 * MB_INST, 64, 18, 16, 14, 7, 0.93, 0.93, 0.93, 0);
          bc[4 * MB_INST + 14] = 4.0 / MB_ATLAS; bc[4 * MB_INST + 15] = 4.0 / MB_ATLAS;
          bc[4 * MB_INST + 21] = 72.0; bc[4 * MB_INST + 22] = 25.0; bc[4 * MB_INST + 23] = bare_ink(16.0, 14.0);

          glass_forget();
          donor_force_off = 0;
          gl_present(bc, 5, 0.06, 0.06, 0.06);
          CHECK(donor_delegated_count == 1);
          unsigned char *bc_on = pixels_of_fb(surface);

          glass_forget();
          donor_force_off = 1;
          gl_present(bc, 5, 0.06, 0.06, 0.06);
          CHECK(donor_delegated_count == 0);
          unsigned char *bc_off = pixels_of_fb(surface);
          donor_force_off = 0;

          unsigned char fg_on = bc_on[boff + 0];
          unsigned char fg_off = bc_off[boff + 0];
          if (((fg_on < 128) != (fg_off < 128)) && abs((int)fg_on - (int)fg_off) >= 100) {
            glass_forget();
            gl_present(bc, 4, 0.06, 0.06, 0.06);
            unsigned char *bc_bg = pixels_of_fb(surface);
            // Measure real composited hidden-title background over the glyph's exact 15-point sampling grid (h=(16,14))
            double sum = 0.0, mx1 = -1.0, mx2 = -1.0, mn1 = 2.0, mn2 = 2.0;
            for (int iy = -1; iy <= 1; iy++) {
              int py = (int)lround((25.0 + iy * (14.0 * 0.60)) * S);
              if (py < 0) py = 0;
              if (py >= fb_h) py = fb_h - 1;
              for (int ix = -2; ix <= 2; ix++) {
                int px = (int)lround((72.0 + ix * (16.0 * 0.38)) * S);
                if (px < 0) px = 0;
                if (px >= fb_w) px = fb_w - 1;
                size_t soff = ((size_t)(fb_h - 1 - py) * fb_w + (size_t)px) * 4;
                double y = wcag_luma_u8(bc_bg[soff + 0], bc_bg[soff + 1], bc_bg[soff + 2]);
                sum += y;
                if (y > mx1) { mx2 = mx1; mx1 = y; } else if (y > mx2) { mx2 = y; }
                if (y < mn1) { mn2 = mn1; mn1 = y; } else if (y < mn2) { mn2 = y; }
              }
            }
            double by_bg = (sum - mx1 - mx2 - mn1 - mn2) / 11.0;
            double by_on = wcag_luma_u8(bc_on[boff + 0], bc_on[boff + 1], bc_on[boff + 2]);
            double by_off = wcag_luma_u8(bc_off[boff + 0], bc_off[boff + 1], bc_off[boff + 2]);
            best_lbg = by_bg;
            best_cr_on = (fmax(by_on, by_bg) + 0.05) / (fmin(by_on, by_bg) + 0.05);
            best_cr_off = (fmax(by_off, by_bg) + 0.05) / (fmin(by_off, by_bg) + 0.05);
            flip_edge = cy;
            flip_on = fg_on; flip_off = fg_off;
            found_flip = 1;
            free(bc_bg);
          }
          free(bc_on); free(bc_off);
        }
        printf("gles_render: perf-51 bright-card flip cy=%d Lbg_real=%.4f cr_on=%.2f cr_off=%.2f fg_on=%u fg_off=%u\n",
               flip_edge, best_lbg, best_cr_on, best_cr_off, flip_on, flip_off);
        CHECK(found_flip == 1);
        CHECK(best_cr_on >= 4.5);
      }

      // Occlusion margin: bright patch between donor and pill outside sr by 4pt but inside cur_glass blur+refract margin (~12pt)
      glass_forget();
      double oc[5 * MB_INST];
      rect_at(oc, 0, 0, W, H, 0, 0.05, 0.05, 0.05, 0);
      rect_at(oc + MB_INST, 0, 0, W, 48, 5, 0, 0, 0, -144);
      oc[MB_INST + 6] = 1.0; oc[MB_INST + 7] = 6.0; oc[MB_INST + 11] = 0.0; oc[MB_INST + 15] = 1.0;
      oc[MB_INST + 22] = -1.0; oc[MB_INST + 54] = 48.0; oc[MB_INST + 55] = 24.0;
      // Intervening bright patch at x=73..79 (sr right edge is 60 + 0.76*12 + 0.5 = 69.62; occ_sr right edge is ~81.8)
      rect_at(oc + 2 * MB_INST, 73, 16, 6, 12, 0, 1.0, 1.0, 1.0, 0);
      rect_at(oc + 3 * MB_INST, 4, 14, 20, 20, 6, 0.14, 0.14, 0.15, -145);
      oc[3 * MB_INST + 4] = 10.0; oc[3 * MB_INST + 6] = 1.0; oc[3 * MB_INST + 7] = 1.4;
      oc[3 * MB_INST + 11] = 0.4; oc[3 * MB_INST + 14] = -1.0; oc[3 * MB_INST + 15] = 1.0;
      oc[3 * MB_INST + 21] = 4.0; oc[3 * MB_INST + 23] = 2.0;
      rect_at(oc + 4 * MB_INST, 54, 16, 12, 12, 7, 0.9, 0.9, 0.9, 0);
      oc[4 * MB_INST + 14] = 4.0 / MB_ATLAS; oc[4 * MB_INST + 15] = 4.0 / MB_ATLAS;
      oc[4 * MB_INST + 21] = 60.0; oc[4 * MB_INST + 22] = 22.0; oc[4 * MB_INST + 23] = bare_ink(12.0, 12.0);
      gl_present(oc, 5, 0.05, 0.05, 0.05);
      CHECK(donor_delegated_count == 0);
    }

    // --- Fix 2c: Lens subtree counterexample (pure kind 5 inside kind 8 is NEVER a donor) ---
    {
      glass_forget();
      double ln[5 * MB_INST];
      rect_at(ln, 0, 0, W, H, 0, 0.05, 0.05, 0.05, 0);
      // kind 8 header with child_n = 1
      rect_at(ln + MB_INST, 0, 0, W, 48, 8, 1, 1, 1, 0);
      ln[MB_INST + 7] = 2.0; ln[MB_INST + 11] = 1.0; ln[MB_INST + 12] = 1.0; ln[MB_INST + 15] = 1.0;
      // child: pure progressive kind 5 (inside lens subtree -> MUST NOT become donor)
      rect_at(ln + 2 * MB_INST, 0, 0, W, 48, 5, 0, 0, 0, -120);
      ln[2 * MB_INST + 6] = 1.0; ln[2 * MB_INST + 7] = 6.0; ln[2 * MB_INST + 11] = 0.0; ln[2 * MB_INST + 15] = 1.0;
      ln[2 * MB_INST + 22] = -1.0; ln[2 * MB_INST + 54] = 48.0; ln[2 * MB_INST + 55] = 24.0;
      // kind 6 pill
      rect_at(ln + 3 * MB_INST, 4, 14, 20, 20, 6, 0.14, 0.14, 0.15, -121);
      ln[3 * MB_INST + 4] = 10.0; ln[3 * MB_INST + 6] = 1.0; ln[3 * MB_INST + 7] = 1.4;
      ln[3 * MB_INST + 11] = 0.4; ln[3 * MB_INST + 14] = -1.0; ln[3 * MB_INST + 15] = 1.0;
      ln[3 * MB_INST + 21] = 4.0; ln[3 * MB_INST + 23] = 2.0;
      // bare adaptive glyph
      rect_at(ln + 4 * MB_INST, 54, 16, 12, 12, 7, 0.2, 0.2, 0.2, 0);
      ln[4 * MB_INST + 14] = 4.0 / MB_ATLAS; ln[4 * MB_INST + 15] = 4.0 / MB_ATLAS;
      ln[4 * MB_INST + 21] = 60.0; ln[4 * MB_INST + 22] = 22.0; ln[4 * MB_INST + 23] = bare_ink(12.0, 12.0);
      gl_present(ln, 5, 0.05, 0.05, 0.05);
      CHECK(donor_delegated_count == 0);
      unsigned char *px = pixels_of_fb(surface);
      unsigned char *tp = px + ((size_t)(fb_h - 1 - 22 * S) * fb_w + 60 * S) * 4;
      CHECK(tp[0] > 180 && tp[1] > 180 && tp[2] > 180);
      free(px);
    }

    // --- Fix 2d: Multi-dirty-rect (cut_on) parity with whole-frame redraw & glass_damage closure ---
    {
      glass_forget();
      double md[8 * MB_INST];
      rect_at(md, 0, 0, W, 40, 0, 0.06, 0.06, 0.06, 0);
      rect_at(md + MB_INST, 0, 40, W, 40, 0, 0.94, 0.94, 0.94, 0);
      // Top donor (-130) + pill (-131) + bare glyph
      rect_at(md + 2 * MB_INST, 0, 0, W, 38, 5, 0, 0, 0, -130);
      md[2 * MB_INST + 6] = 1.0; md[2 * MB_INST + 7] = 5.0; md[2 * MB_INST + 11] = 0.0; md[2 * MB_INST + 15] = 1.0;
      md[2 * MB_INST + 22] = -1.0; md[2 * MB_INST + 54] = 38.0; md[2 * MB_INST + 55] = 16.0;
      rect_at(md + 3 * MB_INST, 4, 8, 16, 16, 6, 0.14, 0.14, 0.15, -131);
      md[3 * MB_INST + 4] = 8.0; md[3 * MB_INST + 6] = 1.0; md[3 * MB_INST + 7] = 1.4;
      md[3 * MB_INST + 11] = 0.4; md[3 * MB_INST + 14] = -1.0; md[3 * MB_INST + 15] = 1.0;
      md[3 * MB_INST + 21] = 4.0; md[3 * MB_INST + 23] = 2.0;
      rect_at(md + 4 * MB_INST, 50, 10, 12, 12, 7, 0.2, 0.2, 0.2, 0);
      md[4 * MB_INST + 14] = 4.0 / MB_ATLAS; md[4 * MB_INST + 15] = 4.0 / MB_ATLAS;
      md[4 * MB_INST + 21] = 56.0; md[4 * MB_INST + 22] = 16.0; md[4 * MB_INST + 23] = bare_ink(12.0, 12.0);
      // Bottom donor (-132) + pill (-133) + bare glyph
      rect_at(md + 5 * MB_INST, 0, 42, W, 38, 5, 0, 0, 0, -132);
      md[5 * MB_INST + 6] = 1.0; md[5 * MB_INST + 7] = 5.0; md[5 * MB_INST + 11] = 0.0; md[5 * MB_INST + 15] = 1.0;
      md[5 * MB_INST + 22] = -1.0; md[5 * MB_INST + 52] = 42.0; md[5 * MB_INST + 53] = 16.0;
      rect_at(md + 6 * MB_INST, 4, 52, 16, 16, 6, 0.14, 0.14, 0.15, -133);
      md[6 * MB_INST + 4] = 8.0; md[6 * MB_INST + 6] = 1.0; md[6 * MB_INST + 7] = 1.4;
      md[6 * MB_INST + 11] = 0.4; md[6 * MB_INST + 14] = -1.0; md[6 * MB_INST + 15] = 1.0;
      md[6 * MB_INST + 21] = 4.0; md[6 * MB_INST + 23] = 2.0;
      rect_at(md + 7 * MB_INST, 50, 54, 12, 12, 7, 0.9, 0.9, 0.9, 0);
      md[7 * MB_INST + 14] = 4.0 / MB_ATLAS; md[7 * MB_INST + 15] = 4.0 / MB_ATLAS;
      md[7 * MB_INST + 21] = 56.0; md[7 * MB_INST + 22] = 60.0; md[7 * MB_INST + 23] = bare_ink(12.0, 12.0);

      // Full baseline frame, then partial redraw with 2 separate dirty rects covering top & bottom titles
      gl_present(md, 8, 0.5, 0.5, 0.5);
      CHECK(donor_delegated_count == 2);
      gl_dirty_add(44, 6, 24, 20);
      gl_dirty_add(44, 50, 24, 20);
      gl_present(md, 8, 0.5, 0.5, 0.5);
      slots_invalidate();
      CHECK(surface_as_whole(surface));
    }

    glass_forget();
    printf("gles_render: perf-51 ok\n");
  }

  // Perf-59: compute_donor_plan() occlusion query cache deduplicates scans across bare glyphs sharing a text box.
  {
    const int N_GLYPHS = 64;
    const int N_TOTAL = 3 + N_GLYPHS;
    float *fc = (float *)calloc((size_t)(N_TOTAL + 1) * MB_INST, sizeof(float));
    CHECK(fc != NULL);
    if (fc) {
      double tmp[MB_INST];
      rect_at(tmp, 0, 0, W, H, 0, 0.05, 0.05, 0.05, 0);
      for (int k = 0; k < MB_INST; k++) fc[k] = (float)tmp[k];
      rect_at(tmp, 0, 0, W, 48, 5, 0, 0, 0, -195);
      tmp[6] = 1.0; tmp[7] = 6.0; tmp[11] = 0.0; tmp[15] = 1.0;
      tmp[22] = -1.0; tmp[54] = 48.0; tmp[55] = 24.0;
      for (int k = 0; k < MB_INST; k++) fc[MB_INST + k] = (float)tmp[k];
      rect_at(tmp, 4, 14, 20, 20, 6, 0.14, 0.14, 0.15, -196);
      tmp[4] = 10.0; tmp[6] = 1.0; tmp[7] = 1.4; tmp[11] = 0.4; tmp[14] = -1.0; tmp[15] = 1.0;
      tmp[21] = 4.0; tmp[23] = 2.0;
      for (int k = 0; k < MB_INST; k++) fc[2 * MB_INST + k] = (float)tmp[k];
      for (int g = 0; g < N_GLYPHS; g++) {
        rect_at(tmp, 44.0 + (g % 32), 16.0, 6.0, 10.0, 7, 0.9, 0.9, 0.9, 0);
        tmp[21] = 60.0; tmp[22] = 22.0; tmp[23] = bare_ink(14.0, 10.0);
        for (int k = 0; k < MB_INST; k++) fc[(size_t)(3 + g) * MB_INST + k] = (float)tmp[k];
      }
      compute_donor_plan(fc, N_TOTAL, (float)W, (float)H, (float)S);
      CHECK(donor_delegated_count == N_GLYPHS);
      CHECK(donor_occ_scans == 1);
      for (int g = 0; g < N_GLYPHS; g++) CHECK(donor_of_buf[3 + g] == -195);

      // Insert an opaque occluder between donor and pill overlapping box B (cx=82), leaving box A (cx=46) clear.
      memmove(fc + 3 * MB_INST, fc + 2 * MB_INST, (size_t)(1 + N_GLYPHS) * MB_INST * sizeof(float));
      rect_at(tmp, 76, 16, 12, 12, 0, 1.0, 1.0, 1.0, 0);
      for (int k = 0; k < MB_INST; k++) fc[2 * MB_INST + k] = (float)tmp[k];
      for (int g = 0; g < N_GLYPHS; g++) {
        float *gp = fc + (size_t)(4 + g) * MB_INST;
        gp[21] = (g < 32) ? 46.0f : 82.0f;
        gp[22] = 22.0f;
        gp[23] = (float)bare_ink(8.0, 8.0);
      }
      compute_donor_plan(fc, N_TOTAL + 1, (float)W, (float)H, (float)S);
      CHECK(donor_delegated_count == 32);
      CHECK(donor_occ_scans == 2);
      for (int g = 0; g < 32; g++) CHECK(donor_of_buf[4 + g] == -195);
      for (int g = 32; g < N_GLYPHS; g++) CHECK(donor_of_buf[4 + g] == 0);

      // Same occ_sr box under two different cur_glass_start pills with an occluder between pill 1 and pill 2:
      // pill 1's glyphs are delegated, pill 2's glyphs are occluded, donor_occ_scans == 2.
      memset(fc, 0, (size_t)(N_TOTAL + 1) * MB_INST * sizeof(float));
      rect_at(tmp, 0, 0, W, H, 0, 0.05, 0.05, 0.05, 0);
      for (int k = 0; k < MB_INST; k++) fc[k] = (float)tmp[k];
      rect_at(tmp, 0, 0, W, 48, 5, 0, 0, 0, -195);
      tmp[6] = 1.0; tmp[7] = 6.0; tmp[11] = 0.0; tmp[15] = 1.0;
      tmp[22] = -1.0; tmp[54] = 48.0; tmp[55] = 24.0;
      for (int k = 0; k < MB_INST; k++) fc[MB_INST + k] = (float)tmp[k];
      rect_at(tmp, 4, 14, 20, 20, 6, 0.14, 0.14, 0.15, -196);
      tmp[4] = 10.0; tmp[6] = 1.0; tmp[7] = 1.4; tmp[11] = 0.4; tmp[14] = -1.0; tmp[15] = 1.0;
      tmp[21] = 4.0; tmp[23] = 2.0;
      for (int k = 0; k < MB_INST; k++) fc[2 * MB_INST + k] = (float)tmp[k];
      for (int g = 0; g < 4; g++) {
        rect_at(tmp, 52.0 + g * 3.0, 16.0, 6.0, 10.0, 7, 0.9, 0.9, 0.9, 0);
        tmp[21] = 60.0; tmp[22] = 22.0; tmp[23] = bare_ink(12.0, 8.0);
        for (int k = 0; k < MB_INST; k++) fc[(size_t)(3 + g) * MB_INST + k] = (float)tmp[k];
      }
      rect_at(tmp, 54, 16, 12, 12, 0, 1.0, 1.0, 1.0, 0);
      for (int k = 0; k < MB_INST; k++) fc[7 * MB_INST + k] = (float)tmp[k];
      memcpy(fc + 8 * MB_INST, fc + 2 * MB_INST, MB_INST * sizeof(float));
      fc[8 * MB_INST + 20] = -197.0f;
      for (int g = 0; g < 4; g++) {
        memcpy(fc + (size_t)(9 + g) * MB_INST, fc + (size_t)(3 + g) * MB_INST, MB_INST * sizeof(float));
      }
      compute_donor_plan(fc, 13, (float)W, (float)H, (float)S);
      CHECK(donor_delegated_count == 4);
      CHECK(donor_occ_scans == 2);
      for (int g = 0; g < 4; g++) CHECK(donor_of_buf[3 + g] == -195);
      for (int g = 0; g < 4; g++) CHECK(donor_of_buf[9 + g] == 0);
      free(fc);
      printf("gles_render: perf-59 ok\n");
    }
  }

  // Liquid glass (kind 6) over a native-view hole (kind 9 under MB_VIEWS_UNDER): outputs translucent premultiplied
  // alpha (rgb <= a, Light ~144, Dark ~192) instead of flat opaque 202/255 grey, and partial redraw matches whole frame.
  {
    test_under_tid = MB_VIEW_TEX + 7;
    double lh[2 * MB_INST];
    rect_at(lh, 0, 0, W, H, 9, 0, 0, 0, MB_VIEW_TEX + 7);
    lh[12] = 0; lh[13] = 0; lh[14] = 1; lh[15] = 1;
    // Light liquid_panel_glass (0xFDFCFD80)
    rect_at(lh + MB_INST, 10, 12, 80, 48, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -210);
    lh[MB_INST + 4] = 18.0; lh[MB_INST + 6] = 1.0; lh[MB_INST + 7] = 8.0;
    lh[MB_INST + 11] = 128.0 / 255.0; lh[MB_INST + 12] = 0.55; lh[MB_INST + 13] = 10.0;
    lh[MB_INST + 15] = 1.0; lh[MB_INST + 21] = 10.0; lh[MB_INST + 22] = 0.08;
    glass_forget();
    gl_present(lh, 2, 0.0, 0.0, 0.0);
    unsigned char *px_l = pixels_of_fb(surface);
    unsigned char *cl = px_l + ((size_t)(fb_h - 1 - 36 * S) * fb_w + 50 * S) * 4;
    printf("gles_render: liquid-over-hole light raw=(%u,%u,%u,a=%u)\n", cl[0], cl[1], cl[2], cl[3]);
    CHECK(cl[3] >= 132 && cl[3] <= 156);
    CHECK(cl[0] <= cl[3] && cl[1] <= cl[3] && cl[2] <= cl[3]);
    CHECK(cl[0] >= 130 && cl[1] >= 130 && cl[2] >= 130);
    free(px_l);

    // Partial redraw of a corner of the through glass card must match a whole redraw byte-for-byte
    gl_dirty_add(10, 12, 40, 24);
    gl_present(lh, 2, 0.0, 0.0, 0.0);
    slots_invalidate();
    CHECK(surface_as_whole(surface));

    // Dark liquid_panel_glass (0x20202080)
    lh[MB_INST + 8] = 32.0 / 255.0; lh[MB_INST + 9] = 32.0 / 255.0; lh[MB_INST + 10] = 32.0 / 255.0;
    lh[MB_INST + 20] = -211;
    glass_forget();
    gl_present(lh, 2, 0.0, 0.0, 0.0);
    unsigned char *px_d = pixels_of_fb(surface);
    unsigned char *cd = px_d + ((size_t)(fb_h - 1 - 36 * S) * fb_w + 50 * S) * 4;
    int comp_dw = cd[0] + (255 * (255 - cd[3]) + 127) / 255;
    printf("gles_render: liquid-over-hole dark raw=(%u,%u,%u,a=%u) over-white=%d\n", cd[0], cd[1], cd[2], cd[3], comp_dw);
    CHECK(cd[3] >= 180 && cd[3] <= 205);
    CHECK(cd[0] <= cd[3] && cd[1] <= cd[3] && cd[2] <= cd[3]);
    CHECK(comp_dw <= 105);
    free(px_d);

    gl_dirty_add(10, 12, 40, 24);
    gl_present(lh, 2, 0.0, 0.0, 0.0);
    slots_invalidate();
    CHECK(surface_as_whole(surface));

    test_under_tid = 0;
    glass_forget();
  }

  // v10_through_hole_adaptive_ink: adaptive Light liquid glass over a real kind==9 native-view hole
  // keeps light glass + dark text (kind==7) + dark opaque adaptive_ink progress bar (kind==0, pad.w<0),
  // while an identical capsule on the opaque pure black stage (a==1) flips to dark glass + bright white ink.
  {
    GLuint was_target = target_fb, th_tex = 0, th_fb = 0;
    int was_fw = fb_w, was_fh = fb_h;
    double was_w = cur_w, was_h = cur_h, was_s = cur_scale;
    if (canvas_fb) {
      glDeleteFramebuffers(1, &canvas_fb);
      glDeleteTextures(1, &canvas_tex);
      canvas_lost();
    }
    glass_free();
    fb_w = 400 * 2; fb_h = 240 * 2; cur_w = 400; cur_h = 240; cur_scale = 2;
    glGenTextures(1, &th_tex);
    glBindTexture(GL_TEXTURE_2D, th_tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
    glGenFramebuffers(1, &th_fb);
    glBindFramebuffer(GL_FRAMEBUFFER, th_fb);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, th_tex, 0);
    target_fb = th_fb;

    unsigned char solid_g[16 * 16];
    memset(solid_g, 255, sizeof solid_g);
    glBindTexture(GL_TEXTURE_2D, atlas);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 16, 16, 16, 16, GL_RED, GL_UNSIGNED_BYTE, solid_g);

    test_under_tid = MB_VIEW_TEX + 7;
    double th[11 * MB_INST];
    rect_at(th + 0 * MB_INST, 0, 0, 400, 240, 0, 0.0, 0.0, 0.0, 0);
    rect_at(th + 1 * MB_INST, 0, 0, 200, 240, 9, 0.0, 0.0, 0.0, MB_VIEW_TEX + 7);
    th[1 * MB_INST + 12] = 0; th[1 * MB_INST + 13] = 0; th[1 * MB_INST + 14] = 1; th[1 * MB_INST + 15] = 1;
    // Capsule A over raw kind==9 hole: (20, 36, 160, 48), center (100, 60)
    rect_at(th + 2 * MB_INST, 20, 36, 160, 48, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -381);
    th[2 * MB_INST + 4] = 24.0; th[2 * MB_INST + 6] = 1.0; th[2 * MB_INST + 7] = 2.0;
    th[2 * MB_INST + 11] = 0x67 / 255.0; th[2 * MB_INST + 12] = 0.0; th[2 * MB_INST + 13] = 14.0;
    th[2 * MB_INST + 14] = -1.0; th[2 * MB_INST + 15] = 1.0;
    // Capsule A text (kind==7, 0x18181BFF) at center (56, 60)
    rect_at(th + 3 * MB_INST, 48, 52, 16, 16, 7, 24.0 / 255.0, 24.0 / 255.0, 27.0 / 255.0, 0);
    th[3 * MB_INST + 12] = 16.0; th[3 * MB_INST + 13] = 16.0; th[3 * MB_INST + 14] = 16.0; th[3 * MB_INST + 15] = 16.0;
    th[3 * MB_INST + 21] = 100.0; th[3 * MB_INST + 22] = 60.0; th[3 * MB_INST + 23] = 48.0;
    // Capsule A opaque adaptive_ink progress bar (kind==0, pad.w=-48, 0x18181BFF) at center (134, 60)
    rect_at(th + 4 * MB_INST, 104, 52, 60, 16, 0, 24.0 / 255.0, 24.0 / 255.0, 27.0 / 255.0, 0);
    th[4 * MB_INST + 4] = 8.0;
    th[4 * MB_INST + 21] = 100.0; th[4 * MB_INST + 22] = 60.0; th[4 * MB_INST + 23] = -48.0;
    // Capsule B over opaque pure black stage: (220, 36, 160, 48), center (300, 60)
    rect_at(th + 5 * MB_INST, 220, 36, 160, 48, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -382);
    th[5 * MB_INST + 4] = 24.0; th[5 * MB_INST + 6] = -1.0; th[5 * MB_INST + 7] = 2.0;
    th[5 * MB_INST + 11] = 0x67 / 255.0; th[5 * MB_INST + 12] = 0.0; th[5 * MB_INST + 13] = 14.0;
    th[5 * MB_INST + 14] = -1.0; th[5 * MB_INST + 15] = 1.0;
    // Capsule B text (kind==7, 0x18181BFF) at center (256, 60)
    rect_at(th + 6 * MB_INST, 248, 52, 16, 16, 7, 24.0 / 255.0, 24.0 / 255.0, 27.0 / 255.0, 0);
    th[6 * MB_INST + 12] = 16.0; th[6 * MB_INST + 13] = 16.0; th[6 * MB_INST + 14] = 16.0; th[6 * MB_INST + 15] = 16.0;
    th[6 * MB_INST + 21] = 300.0; th[6 * MB_INST + 22] = 60.0; th[6 * MB_INST + 23] = 48.0;
    // Capsule B opaque adaptive_ink progress bar (kind==0, pad.w=-48, 0x18181BFF) at center (334, 60)
    rect_at(th + 7 * MB_INST, 304, 52, 60, 16, 0, 24.0 / 255.0, 24.0 / 255.0, 27.0 / 255.0, 0);
    th[7 * MB_INST + 4] = 8.0;
    th[7 * MB_INST + 21] = 300.0; th[7 * MB_INST + 22] = 60.0; th[7 * MB_INST + 23] = -48.0;
    // 70% dark scrim (rgba(0,0,0,0.70)) over bottom-left kind==9 hole: (10, 150, 180, 70)
    rect_at(th + 8 * MB_INST, 10, 150, 180, 70, 0, 0.0, 0.0, 0.0, 0);
    th[8 * MB_INST + 11] = 0.70;
    // Capsule C over 70% dark scrim on kind==9 hole: (20, 160, 160, 50), center (100, 185)
    rect_at(th + 9 * MB_INST, 20, 160, 160, 50, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -383);
    th[9 * MB_INST + 4] = 24.0; th[9 * MB_INST + 6] = -1.0; th[9 * MB_INST + 7] = 2.0;
    th[9 * MB_INST + 11] = 0x67 / 255.0; th[9 * MB_INST + 12] = 0.0; th[9 * MB_INST + 13] = 14.0;
    th[9 * MB_INST + 14] = -1.0; th[9 * MB_INST + 15] = 1.0;
    // Capsule C dark adaptive text (kind==7, #1A1A1A) at center (100, 185)
    rect_at(th + 10 * MB_INST, 92, 177, 16, 16, 7, 26.0 / 255.0, 26.0 / 255.0, 26.0 / 255.0, 0);
    th[10 * MB_INST + 12] = 16.0; th[10 * MB_INST + 13] = 16.0; th[10 * MB_INST + 14] = 16.0; th[10 * MB_INST + 15] = 16.0;
    th[10 * MB_INST + 21] = 100.0; th[10 * MB_INST + 22] = 185.0; th[10 * MB_INST + 23] = 50.0;
    for (int k = 0; k < 11; k++) {
      th[k * MB_INST + 16] = 0.0; th[k * MB_INST + 17] = 0.0;
      th[k * MB_INST + 18] = 400.0; th[k * MB_INST + 19] = 240.0;
    }

    glass_forget();
    gl_present(th, 11, 0.0, 0.0, 0.0);
    unsigned char *px_th = pixels_of_fb(th_fb);
    unsigned char *a_gl = px_th + ((size_t)(fb_h - 1 - 60 * 2) * fb_w + 84 * 2) * 4;
    unsigned char *a_tx = px_th + ((size_t)(fb_h - 1 - 60 * 2) * fb_w + 56 * 2) * 4;
    unsigned char *a_br = px_th + ((size_t)(fb_h - 1 - 60 * 2) * fb_w + 134 * 2) * 4;
    unsigned char *b_gl = px_th + ((size_t)(fb_h - 1 - 60 * 2) * fb_w + 284 * 2) * 4;
    unsigned char *b_tx = px_th + ((size_t)(fb_h - 1 - 60 * 2) * fb_w + 256 * 2) * 4;
    unsigned char *b_br = px_th + ((size_t)(fb_h - 1 - 60 * 2) * fb_w + 334 * 2) * 4;
    unsigned char *c_tx = px_th + ((size_t)(fb_h - 1 - 185 * 2) * fb_w + 100 * 2) * 4;
    double a_tx_l = (0.2126 * a_tx[0] + 0.7152 * a_tx[1] + 0.0722 * a_tx[2]) / 255.0;
    double a_br_l = (0.2126 * a_br[0] + 0.7152 * a_br[1] + 0.0722 * a_br[2]) / 255.0;
    double b_gl_l = (0.2126 * b_gl[0] + 0.7152 * b_gl[1] + 0.0722 * b_gl[2]) / 255.0;
    double b_tx_l = (0.2126 * b_tx[0] + 0.7152 * b_tx[1] + 0.0722 * b_tx[2]) / 255.0;
    double b_br_l = (0.2126 * b_br[0] + 0.7152 * b_br[1] + 0.0722 * b_br[2]) / 255.0;
    double c_tx_l = (0.2126 * c_tx[0] + 0.7152 * c_tx[1] + 0.0722 * c_tx[2]) / 255.0;
    printf("gles_render: v10_through_hole_adaptive_ink hole=(gl=%u/%u tx=%.3f br=%.3f) stage=(gl=%.3f tx=%.3f br=%.3f) scrim70=(tx=%.3f)\n",
           a_gl[0], a_gl[3], a_tx_l, a_br_l, b_gl_l, b_tx_l, b_br_l, c_tx_l);
    CHECK(a_gl[3] >= 100 && a_gl[3] <= 170 && a_gl[0] >= a_gl[3] - 12);
    CHECK(a_tx_l < 0.25 && a_br_l < 0.25);
    CHECK(b_gl[3] == 255 && b_gl_l < 0.35);
    CHECK(b_tx_l > 0.75 && b_br_l > 0.75);
    CHECK(c_tx_l > 0.75);
    free(px_th);
    test_under_tid = 0;

    if (canvas_fb) {
      glDeleteFramebuffers(1, &canvas_fb);
      glDeleteTextures(1, &canvas_tex);
      canvas_lost();
    }
    glass_free();
    target_fb = was_target; fb_w = was_fw; fb_h = was_fh; cur_w = was_w; cur_h = was_h; cur_scale = was_s;
    glBindFramebuffer(GL_FRAMEBUFFER, target_fb);
    glDeleteFramebuffers(1, &th_fb);
    glDeleteTextures(1, &th_tex);
  }

  // the reflection of what is outside liquid glass (glass_reflect_cases.h)
  glass_reflect_cases();
  {
    // a warm capture redrawn in a part, on a surface 320 × 300 points of its own
    GLuint was_target = target_fb, hot_tex = 0, hot_fb = 0;
    int was_fw = fb_w, was_fh = fb_h;
    double was_w = cur_w, was_h = cur_h, was_s = cur_scale;
    if (canvas_fb) {
      glDeleteFramebuffers(1, &canvas_fb);
      glDeleteTextures(1, &canvas_tex);
      canvas_lost();
    }
    glass_free();
    fb_w = 320 * GR_S, fb_h = 300 * GR_S, cur_w = 320, cur_h = 300, cur_scale = GR_S;
    glGenTextures(1, &hot_tex);
    glBindTexture(GL_TEXTURE_2D, hot_tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
    glGenFramebuffers(1, &hot_fb);
    glBindFramebuffer(GL_FRAMEBUFFER, hot_fb);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, hot_tex, 0);
    target_fb = hot_fb;
    gr_hot_frame_case(gr_window_frame);
    CHECK(glGetError() == GL_NO_ERROR);
    if (canvas_fb) {
      glDeleteFramebuffers(1, &canvas_fb);
      glDeleteTextures(1, &canvas_tex);
      canvas_lost();
    }
    glass_free();
    target_fb = was_target, fb_w = was_fw, fb_h = was_fh, cur_w = was_w, cur_h = was_h, cur_scale = was_s;
    glBindFramebuffer(GL_FRAMEBUFFER, target_fb);
    glDeleteFramebuffers(1, &hot_fb);
    glDeleteTextures(1, &hot_tex);
  }

  // Perf-62: lookahead batch glass capture, direct-to-slot blur, VBO trim (skip trailing kind 12), and exact kind-12
  // segment slicing in under_take/slot_match_under — all verified byte-for-byte identical against unbatched rendering.
  {
    GLuint was_target = target_fb, p62_tex = 0, p62_fb = 0;
    int was_fw = fb_w, was_fh = fb_h;
    double was_w = cur_w, was_h = cur_h, was_s = cur_scale;
    if (canvas_fb) {
      glDeleteFramebuffers(1, &canvas_fb);
      glDeleteTextures(1, &canvas_tex);
      canvas_lost();
    }
    glass_free();
    fb_w = 300; fb_h = 600; cur_w = 150.0; cur_h = 300.0; cur_scale = 2.0;
    glGenTextures(1, &p62_tex);
    glBindTexture(GL_TEXTURE_2D, p62_tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
    glGenFramebuffers(1, &p62_fb);
    glBindFramebuffer(GL_FRAMEBUFFER, p62_fb);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, p62_tex, 0);
    target_fb = p62_fb;
    gl_set_fixed_dt(1.0 / 120.0);

    // 1) 5-capture Chat-like scene (non-overlapping float + bottom scrim + overlapping composer + top scrim + top bar)
    //    and 2-capture Home-like scene + trailing kind-12 shape segments: verify byte-exact parity and counter wins.
    double scene[64 * MB_INST];
    int n = 0;
    // Background rects + two kind-11 shapes (shape A at y=16 under top bar; shape B at y=140 outside all glass)
    for (int i = 0; i < 6; i++) {
      rect_at(scene + n * MB_INST, 4, i * 48.0, 142, 40, 0, 0.2 + 0.1 * i, 0.5, 0.8 - 0.1 * i, 0);
      scene[n * MB_INST + 18] = 150.0; scene[n * MB_INST + 19] = 300.0;
      n++;
    }
    // Shape A (under top bar glass, uses segments 0..5 -> kind-12 index 0)
    rect_at(scene + n * MB_INST, 20, 14, 16, 16, 11, 0.9, 0.2, 0.2, 0);
    scene[n * MB_INST + 12] = 0.0; scene[n * MB_INST + 13] = 6.0;
    scene[n * MB_INST + 18] = 150.0; scene[n * MB_INST + 19] = 300.0;
    n++;
    // Shape B (mid-screen outside glass, uses segments 6..11 -> kind-12 index 1)
    rect_at(scene + n * MB_INST, 20, 140, 16, 16, 11, 0.2, 0.9, 0.2, 0);
    scene[n * MB_INST + 12] = 6.0; scene[n * MB_INST + 13] = 6.0;
    scene[n * MB_INST + 18] = 150.0; scene[n * MB_INST + 19] = 300.0;
    n++;
    // Glass 1: float pill (tid=-1, y=180..210)
    rect_at(scene + n * MB_INST, 110, 180, 32, 30, 6, 1.0, 1.0, 1.0, -1);
    scene[n * MB_INST + 4] = 15.0; scene[n * MB_INST + 6] = 1.15; scene[n * MB_INST + 7] = 1.2;
    scene[n * MB_INST + 11] = 0.404; scene[n * MB_INST + 12] = 0.25; scene[n * MB_INST + 13] = 10.0;
    scene[n * MB_INST + 14] = -1.0; scene[n * MB_INST + 21] = 20.0; scene[n * MB_INST + 22] = 0.06;
    scene[n * MB_INST + 18] = 150.0; scene[n * MB_INST + 19] = 300.0;
    n++;
    // Glass 2: bottom progressive scrim (tid=-2, y=268..300) — independent of Glass 1
    rect_at(scene + n * MB_INST, 0, 268, 150, 32, 5, 0.96, 0.96, 0.97, -2);
    scene[n * MB_INST + 6] = 1.0; scene[n * MB_INST + 7] = 8.5; scene[n * MB_INST + 11] = 0.0;
    scene[n * MB_INST + 15] = 1.0; scene[n * MB_INST + 22] = -1.0;
    scene[n * MB_INST + 52] = 268.0; scene[n * MB_INST + 53] = 18.0;
    scene[n * MB_INST + 18] = 150.0; scene[n * MB_INST + 19] = 300.0;
    n++;
    // Glass 3: composer overlapping Glass 2 (tid=-3, y=246..292)
    rect_at(scene + n * MB_INST, 8, 246, 134, 46, 6, 1.0, 1.0, 1.0, -3);
    scene[n * MB_INST + 4] = 23.0; scene[n * MB_INST + 6] = 1.15; scene[n * MB_INST + 7] = 1.2;
    scene[n * MB_INST + 11] = 0.404; scene[n * MB_INST + 12] = 0.25; scene[n * MB_INST + 13] = 10.0;
    scene[n * MB_INST + 14] = -1.0; scene[n * MB_INST + 21] = 20.0; scene[n * MB_INST + 22] = 0.06;
    scene[n * MB_INST + 18] = 150.0; scene[n * MB_INST + 19] = 300.0;
    n++;
    // Glass 4: top progressive scrim (tid=-4, y=0..48) — independent of Glass 1..3
    rect_at(scene + n * MB_INST, 0, 0, 150, 48, 5, 0.96, 0.96, 0.97, -4);
    scene[n * MB_INST + 6] = 1.0; scene[n * MB_INST + 7] = 8.5; scene[n * MB_INST + 11] = 0.0;
    scene[n * MB_INST + 15] = 1.0; scene[n * MB_INST + 22] = -1.0;
    scene[n * MB_INST + 54] = 48.0; scene[n * MB_INST + 55] = 48.0;
    scene[n * MB_INST + 18] = 150.0; scene[n * MB_INST + 19] = 300.0;
    n++;
    // Glass 5: top bar overlapping Glass 4 (tid=-5, y=4..40)
    rect_at(scene + n * MB_INST, 8, 4, 134, 36, 6, 1.0, 1.0, 1.0, -5);
    scene[n * MB_INST + 4] = 18.0; scene[n * MB_INST + 6] = 1.15; scene[n * MB_INST + 7] = 1.2;
    scene[n * MB_INST + 11] = 0.404; scene[n * MB_INST + 12] = 0.25; scene[n * MB_INST + 13] = 10.0;
    scene[n * MB_INST + 14] = -1.0; scene[n * MB_INST + 21] = 20.0; scene[n * MB_INST + 22] = 0.06;
    scene[n * MB_INST + 18] = 150.0; scene[n * MB_INST + 19] = 300.0;
    n++;
    int drawn_pieces = n;
    // Append 10 trailing kind-12 data instances (index 0 = Shape A segs, index 1 = Shape B segs, 2..9 = extra)
    for (int s = 0; s < 10; s++) {
      memset(scene + n * MB_INST, 0, MB_INST * sizeof(double));
      scene[n * MB_INST + 5] = 12.0;
      scene[n * MB_INST + 0] = 2.0; scene[n * MB_INST + 1] = 2.0;
      scene[n * MB_INST + 2] = 14.0; scene[n * MB_INST + 3] = 14.0;
      n++;
    }

    // Reference render with lookahead forced off
    glass_forget();
    lookahead_force_off = 1;
    gl_present(scene, n, 0.95, 0.95, 0.96);
    unsigned char *px_ref = pixels_of_fb(p62_fb);

    // Optimized render with lookahead enabled
    glass_forget();
    lookahead_force_off = 0;
    lookahead_batched = 0;
    vbo_upload_bytes = 0;
    fb_blits = 0;
    gl_present(scene, n, 0.95, 0.95, 0.96);
    unsigned char *px_opt = pixels_of_fb(p62_fb);
    CHECK(memcmp(px_ref, px_opt, (size_t)fb_w * fb_h * 4) == 0);
    CHECK(lookahead_batched == 2);
    // VBO must only upload drawn_pieces (skipping all 10 trailing kind-12 data instances).
    CHECK(vbo_upload_bytes == (size_t)drawn_pieces * MB_INST * sizeof(float));
    // Direct-to-slot blur: 5 target_fb->lv[0] blits + 3 ad_fb blits = 8 total blits (zero slot_fill blits).
    CHECK(fb_blits == 8);
    free(px_ref);
    free(px_opt);

    // 2) Exact kind-12 segment slicing: changing Shape B's segment (outside all glass) must NOT invalidate any blur;
    //    changing Shape A's segment (under top bar glass) MUST invalidate top scrim + top bar blurs and match fresh.
    int b0 = blurs_made;
    scene[(drawn_pieces + 1) * MB_INST + 2] = 10.0;
    gl_present(scene, n, 0.95, 0.95, 0.96);
    CHECK(blurs_made == b0);
    scene[(drawn_pieces + 0) * MB_INST + 2] = 6.0;
    gl_present(scene, n, 0.95, 0.95, 0.96);
    CHECK(blurs_made > b0);
    CHECK(surface_as_fresh(p62_fb));

    // 3) 2-capture Home-like scene: top bar + bottom tab bar batch into 1 lookahead + 1 batched ad_fb update (3 blits total).
    double home[16 * MB_INST];
    int hn = 0;
    rect_at(home + hn * MB_INST, 0, 0, 150, 300, 0, 0.85, 0.88, 0.92, 0);
    home[hn * MB_INST + 18] = 150.0; home[hn * MB_INST + 19] = 300.0; hn++;
    rect_at(home + hn * MB_INST, 8, 4, 134, 36, 6, 1.0, 1.0, 1.0, -1);
    home[hn * MB_INST + 4] = 18.0; home[hn * MB_INST + 6] = 1.15; home[hn * MB_INST + 7] = 1.2;
    home[hn * MB_INST + 11] = 0.404; home[hn * MB_INST + 12] = 0.25; home[hn * MB_INST + 13] = 10.0;
    home[hn * MB_INST + 14] = -1.0; home[hn * MB_INST + 21] = 20.0; home[hn * MB_INST + 22] = 0.06;
    home[hn * MB_INST + 18] = 150.0; home[hn * MB_INST + 19] = 300.0; hn++;
    rect_at(home + hn * MB_INST, 8, 240, 134, 48, 6, 1.0, 1.0, 1.0, -2);
    home[hn * MB_INST + 4] = 24.0; home[hn * MB_INST + 6] = 1.15; home[hn * MB_INST + 7] = 1.2;
    home[hn * MB_INST + 11] = 0.404; home[hn * MB_INST + 12] = 0.25; home[hn * MB_INST + 13] = 10.0;
    home[hn * MB_INST + 14] = -1.0; home[hn * MB_INST + 21] = 20.0; home[hn * MB_INST + 22] = 0.06;
    home[hn * MB_INST + 18] = 150.0; home[hn * MB_INST + 19] = 300.0; hn++;

    glass_forget();
    lookahead_force_off = 1;
    gl_present(home, hn, 0.95, 0.95, 0.96);
    unsigned char *h_ref = pixels_of_fb(p62_fb);
    glass_forget();
    lookahead_force_off = 0;
    lookahead_batched = 0;
    fb_blits = 0;
    gl_present(home, hn, 0.95, 0.95, 0.96);
    unsigned char *h_opt = pixels_of_fb(p62_fb);
    CHECK(memcmp(h_ref, h_opt, (size_t)fb_w * fb_h * 4) == 0);
    CHECK(lookahead_batched == 1);
    // 2 target_fb->lv[0] blits + 1 batched ad_fb blit = 3 blits total (zero slot_fill blits).
    CHECK(fb_blits == 3);
    free(h_ref);
    free(h_opt);

    // 4) Intervening merged-liquid group spanning across a later glass rect MUST block lookahead and remain byte-identical.
    double merged[12 * MB_INST];
    int mn = 0;
    rect_at(merged + mn * MB_INST, 0, 0, 150, 300, 0, 0.3, 0.5, 0.7, 0);
    merged[mn * MB_INST + 18] = 150.0; merged[mn * MB_INST + 19] = 300.0; mn++;
    // Merged liquid group (tid=-1): two shapes at top (y=10) and bottom (y=230), merge=8 -> u_gb covers y=10..260!
    rect_at(merged + mn * MB_INST, 20, 10, 40, 30, 6, 1.0, 0.4, 0.2, -1);
    merged[mn * MB_INST + 4] = 10.0; merged[mn * MB_INST + 6] = 1.1; merged[mn * MB_INST + 7] = 1.2;
    merged[mn * MB_INST + 11] = 0.45; merged[mn * MB_INST + 21] = 12.0; merged[mn * MB_INST + 23] = 8.0;
    merged[mn * MB_INST + 18] = 150.0; merged[mn * MB_INST + 19] = 300.0; mn++;
    rect_at(merged + mn * MB_INST, 80, 230, 40, 30, 6, 1.0, 0.4, 0.2, -1);
    merged[mn * MB_INST + 4] = 10.0; merged[mn * MB_INST + 6] = 1.1; merged[mn * MB_INST + 7] = 1.2;
    merged[mn * MB_INST + 11] = 0.45; merged[mn * MB_INST + 21] = 12.0; merged[mn * MB_INST + 23] = 8.0;
    merged[mn * MB_INST + 18] = 150.0; merged[mn * MB_INST + 19] = 300.0; mn++;
    // Later glass in the middle (y=110..150): inside merged u_gb, so lookahead MUST refuse it.
    rect_at(merged + mn * MB_INST, 40, 110, 60, 40, 6, 0.2, 0.8, 1.0, -2);
    merged[mn * MB_INST + 4] = 12.0; merged[mn * MB_INST + 6] = 1.1; merged[mn * MB_INST + 7] = 1.2;
    merged[mn * MB_INST + 11] = 0.404; merged[mn * MB_INST + 14] = -1.0; merged[mn * MB_INST + 21] = 14.0;
    merged[mn * MB_INST + 18] = 150.0; merged[mn * MB_INST + 19] = 300.0; mn++;

    glass_forget();
    lookahead_force_off = 1;
    gl_present(merged, mn, 0.2, 0.2, 0.25);
    unsigned char *m_ref = pixels_of_fb(p62_fb);
    glass_forget();
    lookahead_force_off = 0;
    lookahead_batched = 0;
    gl_present(merged, mn, 0.2, 0.2, 0.25);
    unsigned char *m_opt = pixels_of_fb(p62_fb);
    CHECK(memcmp(m_ref, m_opt, (size_t)fb_w * fb_h * 4) == 0);
    CHECK(lookahead_batched == 0);
    free(m_ref);
    free(m_opt);

    // 5) Intervening kind-8 foreground lens overlapping a later glass rect MUST block lookahead and remain byte-identical.
    double lens_sc[10 * MB_INST];
    int ln = 0;
    rect_at(lens_sc + ln * MB_INST, 0, 0, 150, 300, 0, 0.2, 0.3, 0.4, 0);
    lens_sc[ln * MB_INST + 18] = 150.0; lens_sc[ln * MB_INST + 19] = 300.0; ln++;
    rect_at(lens_sc + ln * MB_INST, 8, 4, 134, 36, 6, 1.0, 1.0, 1.0, -1);
    lens_sc[ln * MB_INST + 4] = 18.0; lens_sc[ln * MB_INST + 6] = 1.1; lens_sc[ln * MB_INST + 7] = 1.2;
    lens_sc[ln * MB_INST + 11] = 0.404; lens_sc[ln * MB_INST + 14] = -1.0; lens_sc[ln * MB_INST + 21] = 16.0;
    lens_sc[ln * MB_INST + 18] = 150.0; lens_sc[ln * MB_INST + 19] = 300.0; ln++;
    // kind-8 lens over y=220..270 with 1 child rect
    rect_at(lens_sc + ln * MB_INST, 20, 220, 100, 50, 8, 1.0, 1.0, 1.0, 0);
    lens_sc[ln * MB_INST + 4] = 16.0; lens_sc[ln * MB_INST + 7] = 1.0; lens_sc[ln * MB_INST + 11] = 1.0;
    lens_sc[ln * MB_INST + 12] = 1.0; lens_sc[ln * MB_INST + 13] = 8.0; lens_sc[ln * MB_INST + 14] = 10.0;
    lens_sc[ln * MB_INST + 18] = 150.0; lens_sc[ln * MB_INST + 19] = 300.0; ln++;
    rect_at(lens_sc + ln * MB_INST, 30, 230, 80, 30, 0, 0.95, 0.2, 0.2, 0);
    lens_sc[ln * MB_INST + 18] = 150.0; lens_sc[ln * MB_INST + 19] = 300.0; ln++;
    // Later glass at y=240..280 overlapping the kind-8 lens
    rect_at(lens_sc + ln * MB_INST, 12, 240, 126, 40, 6, 1.0, 1.0, 1.0, -2);
    lens_sc[ln * MB_INST + 4] = 18.0; lens_sc[ln * MB_INST + 6] = 1.1; lens_sc[ln * MB_INST + 7] = 1.2;
    lens_sc[ln * MB_INST + 11] = 0.404; lens_sc[ln * MB_INST + 14] = -1.0; lens_sc[ln * MB_INST + 21] = 16.0;
    lens_sc[ln * MB_INST + 18] = 150.0; lens_sc[ln * MB_INST + 19] = 300.0; ln++;

    glass_forget();
    lookahead_force_off = 1;
    gl_present(lens_sc, ln, 0.2, 0.2, 0.25);
    unsigned char *l_ref = pixels_of_fb(p62_fb);
    glass_forget();
    lookahead_force_off = 0;
    lookahead_batched = 0;
    gl_present(lens_sc, ln, 0.2, 0.2, 0.25);
    unsigned char *l_opt = pixels_of_fb(p62_fb);
    CHECK(memcmp(l_ref, l_opt, (size_t)fb_w * fb_h * 4) == 0);
    CHECK(lookahead_batched == 0);
    CHECK(feedback_loops == 0);
    CHECK(glGetError() == GL_NO_ERROR);
    free(l_ref);
    free(l_opt);

    // 6) Slot-pinning stress test (> MB_GLASS_SLOTS = 32 groups, mixing 30 liquid glass pills + 4 progressive scrims):
    //    verifies lookahead pin budget + defensive fallback never exhausts slots or reads OOB and matches unbatched.
    {
      double stress[40 * MB_INST];
      int sn = 0;
      rect_at(stress + sn * MB_INST, 0, 0, 150, 300, 0, 0.25, 0.35, 0.45, 0);
      stress[sn * MB_INST + 18] = 150.0; stress[sn * MB_INST + 19] = 300.0; sn++;
      for (int g = 0; g < 30; g++) {
        double gx = (g % 5) * 28.0 + 4.0;
        double gy = (g / 5) * 34.0 + 4.0;
        rect_at(stress + sn * MB_INST, gx, gy, 22, 24, 6, 1.0, 1.0, 1.0, -(g + 1));
        stress[sn * MB_INST + 4] = 8.0; stress[sn * MB_INST + 6] = 1.1; stress[sn * MB_INST + 7] = 1.2;
        stress[sn * MB_INST + 11] = 0.404; stress[sn * MB_INST + 14] = -1.0; stress[sn * MB_INST + 21] = 10.0;
        stress[sn * MB_INST + 18] = 150.0; stress[sn * MB_INST + 19] = 300.0; sn++;
      }
      for (int d = 0; d < 4; d++) {
        double dy = 216.0 + d * 20.0;
        rect_at(stress + sn * MB_INST, 0, dy, 150, 18, 5, 0.95, 0.95, 0.96, -(31 + d));
        stress[sn * MB_INST + 6] = 1.0; stress[sn * MB_INST + 7] = 6.0; stress[sn * MB_INST + 11] = 0.0;
        stress[sn * MB_INST + 15] = 1.0; stress[sn * MB_INST + 22] = -1.0;
        stress[sn * MB_INST + 52] = dy; stress[sn * MB_INST + 53] = 12.0;
        stress[sn * MB_INST + 18] = 150.0; stress[sn * MB_INST + 19] = 300.0; sn++;
      }
      glass_forget();
      lookahead_force_off = 1;
      gl_present(stress, sn, 0.25, 0.35, 0.45);
      unsigned char *st_ref = pixels_of_fb(p62_fb);
      glass_forget();
      lookahead_force_off = 0;
      lookahead_batched = 0;
      gl_present(stress, sn, 0.25, 0.35, 0.45);
      unsigned char *st_opt = pixels_of_fb(p62_fb);
      CHECK(lookahead_batched > 0);
      CHECK(memcmp(st_ref, st_opt, (size_t)fb_w * fb_h * 4) == 0);
      CHECK(surface_as_fresh(p62_fb));
      CHECK(feedback_loops == 0);
      CHECK(glGetError() == GL_NO_ERROR);
      free(st_ref);
      free(st_opt);
    }

    // 7) Partial multi-rect redraw (n_rects == 2) with lookahead inside a dirty rect + intervening skind-6 ad_barrier:
    //    verifies lookahead_batched > 0 during partial redraw and byte-exact parity against unbatched rendering.
    {
      double bar[12 * MB_INST];
      int bn = 0;
      rect_at(bar + bn * MB_INST, 0, 0, 150, 300, 0, 0.85, 0.88, 0.92, 0);
      bar[bn * MB_INST + 18] = 150.0; bar[bn * MB_INST + 19] = 300.0; bn++;
      // Group 1 (top left, inside dirty rect 1)
      rect_at(bar + bn * MB_INST, 8, 8, 60, 32, 6, 1.0, 1.0, 1.0, -1);
      bar[bn * MB_INST + 4] = 12.0; bar[bn * MB_INST + 6] = 1.1; bar[bn * MB_INST + 7] = 1.2;
      bar[bn * MB_INST + 11] = 0.404; bar[bn * MB_INST + 14] = -1.0; bar[bn * MB_INST + 21] = 14.0;
      bar[bn * MB_INST + 18] = 150.0; bar[bn * MB_INST + 19] = 300.0; bn++;
      // Intervening rect overlapping Group 2 (middle, inside dirty rect 1)
      rect_at(bar + bn * MB_INST, 20, 100, 100, 40, 0, 0.9, 0.3, 0.2, 0);
      bar[bn * MB_INST + 18] = 150.0; bar[bn * MB_INST + 19] = 300.0; bn++;
      // Group 2 (middle, blocked by intervening rect -> sets ad_barrier)
      rect_at(bar + bn * MB_INST, 24, 104, 92, 32, 6, 1.0, 1.0, 1.0, -2);
      bar[bn * MB_INST + 4] = 12.0; bar[bn * MB_INST + 6] = 1.1; bar[bn * MB_INST + 7] = 1.2;
      bar[bn * MB_INST + 11] = 0.404; bar[bn * MB_INST + 14] = -1.0; bar[bn * MB_INST + 21] = 14.0;
      bar[bn * MB_INST + 18] = 150.0; bar[bn * MB_INST + 19] = 300.0; bn++;
      // Group 3 (also inside dirty rect 1 at y=160..192, spatially independent of intervening rect -> lookahead + ad_barrier=1)
      rect_at(bar + bn * MB_INST, 8, 160, 134, 32, 6, 1.0, 1.0, 1.0, -3);
      bar[bn * MB_INST + 4] = 12.0; bar[bn * MB_INST + 6] = 1.1; bar[bn * MB_INST + 7] = 1.2;
      bar[bn * MB_INST + 11] = 0.404; bar[bn * MB_INST + 14] = -1.0; bar[bn * MB_INST + 21] = 14.0;
      bar[bn * MB_INST + 18] = 150.0; bar[bn * MB_INST + 19] = 300.0; bn++;
      // Group 4 (bottom, inside disjoint dirty rect 2)
      rect_at(bar + bn * MB_INST, 8, 250, 134, 40, 6, 1.0, 1.0, 1.0, -4);
      bar[bn * MB_INST + 4] = 14.0; bar[bn * MB_INST + 6] = 1.1; bar[bn * MB_INST + 7] = 1.2;
      bar[bn * MB_INST + 11] = 0.404; bar[bn * MB_INST + 14] = -1.0; bar[bn * MB_INST + 21] = 14.0;
      bar[bn * MB_INST + 18] = 150.0; bar[bn * MB_INST + 19] = 300.0; bn++;

      // Warm up full frame into canvas, then partial redraw with 2 disjoint dirty rects (0..210 covers g1+g2+g3; 235..300 covers g4)
      glass_forget();
      lookahead_force_off = 1;
      gl_present(bar, bn, 0.85, 0.88, 0.92);
      bar[0 * MB_INST + 8] = 0.4; // mutate background
      gl_dirty_add(0, 0, 150, 210);
      gl_dirty_add(0, 235, 150, 65);
      gl_present(bar, bn, 0.85, 0.88, 0.92);
      unsigned char *p_ref = pixels_of_fb(p62_fb);

      bar[0 * MB_INST + 8] = 0.85;
      glass_forget();
      lookahead_force_off = 0;
      gl_present(bar, bn, 0.85, 0.88, 0.92);
      bar[0 * MB_INST + 8] = 0.4;
      lookahead_batched = 0;
      gl_dirty_add(0, 0, 150, 210);
      gl_dirty_add(0, 235, 150, 65);
      gl_present(bar, bn, 0.85, 0.88, 0.92);
      unsigned char *p_opt = pixels_of_fb(p62_fb);
      CHECK(lookahead_batched >= 1);
      CHECK(memcmp(p_ref, p_opt, (size_t)fb_w * fb_h * 4) == 0);
      CHECK(feedback_loops == 0);
      CHECK(glGetError() == GL_NO_ERROR);
      free(p_ref);
      free(p_opt);
    }

    gl_set_fixed_dt(0.0);
    if (canvas_fb) {
      glDeleteFramebuffers(1, &canvas_fb);
      glDeleteTextures(1, &canvas_tex);
      canvas_lost();
    }
    glass_free();
    target_fb = was_target; fb_w = was_fw; fb_h = was_fh; cur_w = was_w; cur_h = was_h; cur_scale = was_s;
    glBindFramebuffer(GL_FRAMEBUFFER, target_fb);
    glDeleteFramebuffers(1, &p62_fb);
    glDeleteTextures(1, &p62_tex);
    printf("gles_render: p62 lookahead + direct-slot-blur + vbo-trim + seg-slice ok\n");
  }

  if (!failed) printf("gles_render: ok\n");
  return failed;
}
