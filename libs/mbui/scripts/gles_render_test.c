// src/host/gles_render.h's tests on the window's way (not mbui-render's offscreen one: Android's surface, Linux's
// window), in OpenGL ES 3 on EGL's surfaceless platform (Mesa's llvmpipe where there is no GPU), a framebuffer of the
// test's own standing for the surface (target_fb): a frame drawn whole goes straight onto it, no canvas made; one said
// to differ in parts is drawn into the canvas and shown, the surface then the same to the byte as the frame drawn
// whole; the blur under glass kept while what is under it is the same, made again once it is not, never kept while a
// picture under it had no texture yet; a group the host keeps drawn out to the float the app's own instance would be.
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
