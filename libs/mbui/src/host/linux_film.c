// mbui's film on Linux (src/film), as src/host/apple_film.m is Apple's: a frame's instances drawn by the host's
// renderer offscreen (linux_render.c: OpenGL ES 3 on EGL's surfaceless platform, Mesa's llvmpipe where there is no
// GPU), read back drawn whole (gles_render.h's mb_render_drawn_pixels, rows from the top) and written into an H.264
// MP4 by ffmpeg (libx264, on PATH or MBUI_FFMPEG) as the frame it is to be; and what a program run from the command
// line needs besides: its arguments, a line said, a file read or written, GLib's main context turned for what the host
// tells there.
#include <epoxy/gl.h>
#include <errno.h>
#include <glib.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "linux.h"

void mb_host_present(double *buf, int32_t count, double r, double g, double b);
int32_t mb_render_drawn_pixels(int32_t x, int32_t y, int32_t w, int32_t h, moonbit_bytes_t out);
void mb_host_render_dirty(double x, double y, double w, double h);

static char *utf8_of(moonbit_string_t s) {
  char *out = g_utf16_to_utf8((const gunichar2 *)s, Moonbit_array_length(s), NULL, NULL, NULL);
  return out ? out : g_strdup("");
}

static moonbit_string_t mb_of(const char *s) {
  glong n = 0;
  gunichar2 *u = s ? g_utf8_to_utf16(s, -1, NULL, &n, NULL) : NULL;
  if (!u) n = 0;
  moonbit_string_t out = moonbit_make_string((int32_t)n, 0);
  if (n) memcpy(out, u, (size_t)n * 2);
  g_free(u);
  return out;
}

// ---- the size frames are drawn at ----

// The offscreen framebuffer frames are drawn into at the size set (the film's scene sets it before each frame: its
// window's zoom), made anew as the size changes; the one mb_render_init_offscreen made is left as it is.
static GLuint size_fb, size_tex;
static int size_pw, size_ph;
static double size_w, size_h, size_scale;

void mb_render_set_size(double w, double h, double scale) {
  int pw = (int)floor(w * scale + 0.5), ph = (int)floor(h * scale + 0.5);
  if (pw <= 0 || ph <= 0) return;
  if (size_fb && w == size_w && h == size_h && scale == size_scale) return;
  if (!size_fb || pw != size_pw || ph != size_ph) {
    if (size_fb) {
      glDeleteFramebuffers(1, &size_fb);
      glDeleteTextures(1, &size_tex);
    }
    glGenTextures(1, &size_tex);
    glBindTexture(GL_TEXTURE_2D, size_tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, pw, ph);
    glGenFramebuffers(1, &size_fb);
    glBindFramebuffer(GL_FRAMEBUFFER, size_fb);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, size_tex, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) fprintf(stderr, "film: no framebuffer\n");
  }
  glBindFramebuffer(GL_FRAMEBUFFER, size_fb);
  // (the framebuffer bound is what the renderer draws into from now on)
  mb_render_target(pw, ph, w, h, scale);
  size_pw = pw, size_ph = ph, size_w = w, size_h = h, size_scale = scale;
}

// ---- the film ----

// ffmpeg's input, raw RGBA frames at a constant rate: a frame is written for every frame of the film, the picture put
// last repeated over those the run did not put.
static FILE *film_pipe;
static char *film_destination, *film_temporary;
static int32_t film_w, film_h, film_fps, film_written;
// the picture drawn last (what the next frame put is) and the one put last (what the frames before it are)
static uint8_t *film_shown, *film_put;
static int film_has_shown, film_has_put;

static char *quoted(const char *s) {
  GString *q = g_string_new("'");
  for (const char *p = s; *p; p++) {
    if (*p == '\'') g_string_append(q, "'\\''");
    else g_string_append_c(q, *p);
  }
  g_string_append_c(q, '\'');
  return g_string_free(q, FALSE);
}

static void film_forget(void) {
  free(film_shown);
  free(film_put);
  film_shown = film_put = NULL;
  film_has_shown = film_has_put = 0;
  film_written = 0;
}

static void film_discard_open(void) {
  if (film_pipe) pclose(film_pipe);
  film_pipe = NULL;
  if (film_temporary) unlink(film_temporary);
  g_free(film_temporary);
  g_free(film_destination);
  film_temporary = film_destination = NULL;
  film_forget();
}

// A film begun for `path`, `w` × `h` pixels (to even numbers, as H.264's 4:2:0 has them), `fps` frames a second,
// written beside it and put in its place only once whole (mbf_finish): 1, or 0 with what went wrong said.
int32_t mbf_open(moonbit_string_t path, int32_t w, int32_t h, int32_t fps) {
  film_discard_open();
  film_w = w & ~1;
  film_h = h & ~1;
  film_fps = fps;
  if (film_w <= 0 || film_h <= 0 || fps <= 0) {
    fprintf(stderr, "film: no film of %d x %d at %d fps\n", w, h, fps);
    return 0;
  }
  film_destination = utf8_of(path);
  char *dir = g_path_get_dirname(film_destination), *base = g_path_get_basename(film_destination);
  char *name = g_strdup_printf(".%s.%d.%08x.tmp.mp4", base, (int)getpid(), g_random_int());
  film_temporary = g_build_filename(dir, name, NULL);
  g_free(dir);
  g_free(base);
  g_free(name);
  const char *ffmpeg = getenv("MBUI_FFMPEG");
  char *exe = quoted(ffmpeg && *ffmpeg ? ffmpeg : "ffmpeg"), *out = quoted(film_temporary);
  // (the renderer's pixels as a screen's: BT.709, as players take a screen's recording, and as apple_film.m writes;
  // a key frame each second, no B-frames, about the bit rate Apple's writer is asked for)
  char *cmd = g_strdup_printf(
      "%s -hide_banner -loglevel error -nostdin -y -f rawvideo -pix_fmt rgba -s %dx%d -framerate %d -i - "
      "-vf scale=out_color_matrix=bt709:out_range=tv -c:v libx264 -preset medium -profile:v high -pix_fmt yuv420p "
      "-b:v %d -g %d -bf 0 -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv "
      "-movflags +faststart -f mp4 %s",
      exe, film_w, film_h, fps, film_w * film_h * 6, fps, out);
  g_free(exe);
  g_free(out);
  // (an encoder gone is told by a write that fails, not by the signal that would end this process)
  signal(SIGPIPE, SIG_IGN);
  film_pipe = popen(cmd, "w");
  g_free(cmd);
  if (!film_pipe) {
    fprintf(stderr, "film: ffmpeg did not start (%s)\n", strerror(errno));
    film_discard_open();
    return 0;
  }
  size_t n = (size_t)film_w * film_h * 4;
  film_shown = calloc(1, n);
  film_put = calloc(1, n);
  return 1;
}

// The instances drawn offscreen and read back drawn whole into a picture of the film's (the picture the next frames
// written are): 1, or 0 when nothing could be drawn or read.
int32_t mbf_draw(const double *inst, int32_t count, double r, double g, double b) {
  if (!film_pipe) return 0;
  mb_host_present((double *)inst, count, r, g, b);
  // (the frame as drawn at the size set, its part the film holds: its top left)
  int fw = size_fb ? size_pw : film_w, fh = size_fb ? size_ph : film_h;
  int cols = fw < film_w ? fw : film_w, rows = fh < film_h ? fh : film_h;
  moonbit_bytes_t px = moonbit_make_bytes((int32_t)((size_t)cols * rows * 4), 0);
  int ok = mb_render_drawn_pixels(0, 0, cols, rows, px);
  if (ok) {
    if (cols < film_w || rows < film_h) memset(film_shown, 0, (size_t)film_w * film_h * 4);
    for (int y = 0; y < rows; y++)
      memcpy(film_shown + (size_t)y * film_w * 4, px + (size_t)y * cols * 4, (size_t)cols * 4);
    film_has_shown = 1;
  }
  moonbit_decref(px);
  return ok;
}

static int film_write(const uint8_t *px) {
  size_t n = (size_t)film_w * film_h * 4;
  if (fwrite(px, 1, n, film_pipe) != n) {
    fprintf(stderr, "film: frame %d: ffmpeg took no more (%s)\n", film_written, strerror(errno));
    return 0;
  }
  film_written++;
  return 1;
}

// The picture drawn last written as frame `k` (k / fps s in), the frames since the one put before it that picture:
// 1, or 0 with what went wrong said.
int32_t mbf_put(int32_t k) {
  if (!film_pipe || !film_has_shown) return 0;
  if (k < film_written) {
    fprintf(stderr, "film: frame %d put after frame %d\n", k, film_written - 1);
    return 0;
  }
  while (film_written < k)
    if (!film_write(film_has_put ? film_put : film_shown)) return 0;
  if (!film_write(film_shown)) return 0;
  memcpy(film_put, film_shown, (size_t)film_w * film_h * 4);
  film_has_put = 1;
  return 1;
}

// The film ended after `frames` frames (the picture put last held to its end) and written out whole: 1, or 0 with
// what went wrong said.
int32_t mbf_close(int32_t frames) {
  if (!film_pipe) return 0;
  int ok = 1;
  while (ok && film_has_put && film_written < frames) ok = film_write(film_put);
  int status = pclose(film_pipe);
  film_pipe = NULL;
  if (status == -1 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    fprintf(stderr, "film: not written out (ffmpeg %s %d)\n", WIFEXITED(status) ? "ended with" : "stopped by",
            WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? WTERMSIG(status) : status));
    ok = 0;
  }
  film_forget();
  return ok;
}

// Publish a completed take by an atomic rename, or discard an unsuccessful one. The old destination is untouched on
// failure. Both paths are in the same directory, so the rename does not cross filesystems.
int32_t mbf_finish(int32_t publish) {
  if (!film_temporary || !film_destination) return 0;
  int ok = 1;
  if (publish && rename(film_temporary, film_destination) != 0) {
    perror("film: could not publish");
    ok = 0;
  }
  if (!publish || !ok) unlink(film_temporary);
  g_free(film_temporary);
  g_free(film_destination);
  film_temporary = film_destination = NULL;
  return ok;
}

// ---- a picture ----

// The frame drawn last as it was drawn (the renderer's own pixels, not the film's encoding of them) written to `path`
// as a PNG beside it, then renamed into place: a failed render or write leaves the old picture alone. 1, or 0.
int32_t mbf_snapshot(moonbit_string_t path) {
  char *destination = utf8_of(path);
  char *dir = g_path_get_dirname(destination), *base = g_path_get_basename(destination);
  char *name = g_strdup_printf(".%s.%d.%08x.tmp.png", base, (int)getpid(), g_random_int());
  char *temporary = g_build_filename(dir, name, NULL);
  int ok = mb_render_snapshot(temporary);
  if (ok && rename(temporary, destination) != 0) ok = 0;
  if (!ok) unlink(temporary);
  g_free(dir);
  g_free(base);
  g_free(name);
  g_free(temporary);
  g_free(destination);
  return ok;
}

// A picture over a transparent ground: this renderer clears its frames opaque (gles_render.h), so there is none yet.
int32_t mbf_snapshot_transparent(moonbit_string_t path) {
  (void)path;
  fprintf(stderr, "film: no transparent picture on Linux yet (MBUI_PICTURE_TRANSPARENT): its renderer draws opaque\n");
  return 0;
}

// ---- the process ----

// GLib's main context turned for what is told there (a picture decoded, what was posted), then `ms` let pass.
void mbf_spin(double ms) {
  while (g_main_context_iteration(NULL, FALSE)) {
  }
  if (ms > 0) {
    struct timespec t = {(time_t)(ms / 1000), (long)(fmod(ms, 1000) * 1e6)};
    nanosleep(&t, NULL);
  }
}

// The process's environment variable `name` ("" when unset).
moonbit_string_t mbf_arg(moonbit_string_t name) {
  char *n = utf8_of(name);
  const char *v = getenv(n);
  g_free(n);
  return mb_of(v ? v : "");
}

void mbf_say(moonbit_string_t s) {
  char *t = utf8_of(s);
  fprintf(stderr, "%s\n", t);
  g_free(t);
}

// The file at `path` (UTF-8) as text ("" when it cannot be read).
moonbit_string_t mbf_read_text(moonbit_string_t path) {
  char *p = utf8_of(path), *text = NULL;
  gsize n = 0;
  moonbit_string_t out = mb_of(g_file_get_contents(p, &text, &n, NULL) && g_utf8_validate(text, (gssize)n, NULL)
                                   ? text : "");
  g_free(text);
  g_free(p);
  return out;
}

// `text` written to the file at `path` (UTF-8), whole or not at all: 1, or 0 when it could not be.
int32_t mbf_write_text(moonbit_string_t path, moonbit_string_t text) {
  char *p = utf8_of(path), *t = utf8_of(text);
  int ok = g_file_set_contents(p, t, -1, NULL) ? 1 : 0;
  g_free(p);
  g_free(t);
  return ok;
}

// (film here: what it asks of the renderer through calls of its own, which src/host/film_none.c answers elsewhere)
int32_t mbf_supported(void) { return 1; }
void mbf_set_view(double w, double h, double scale) { mb_render_set_size(w, h, scale); }
void mbf_text_scale(double scale) { mb_text_set_scale(scale); }
void mbf_dirty(double x, double y, double w, double h) { mb_host_render_dirty(x, y, w, h); }

// The machine's clock (ms, monotonic): what a bench over a Tester times the frame's work by.
double mbf_now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

void mbf_exit(int32_t code) {
  fflush(stderr);
  exit(code);
}
